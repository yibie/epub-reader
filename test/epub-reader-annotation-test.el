;;; epub-reader-annotation-test.el --- Bookmark and annotation tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'textui)
(require 'epub-reader-annotation)
(require 'epub-reader-render)
(require 'epub-reader-test-helper)

(defvar epub-reader-annotation-test--width 18)

(defun epub-reader-annotation-test--frame (_available-width)
  "Render fixture blocks at `epub-reader-annotation-test--width'."
  (list
   (list :type :flex :direction :column :gap 1
         :layout (list :width epub-reader-annotation-test--width
                       :min-width epub-reader-annotation-test--width)
         :children (epub-reader-render-blocks
                    (plist-get textui-state :blocks)))))

(cl-defmacro epub-reader-annotation-test--with-language-buffer
    ((buffer publication blocks) &rest body)
  "Open the language fixture and bind BUFFER, PUBLICATION, and BLOCKS."
  (declare (indent 1) (debug (sexp body)))
  `(let* ((,publication
           (epub-reader-publication-open
            (epub-reader-test-fixture "language-mix.epub")))
          (,blocks (vconcat (epub-reader-render-chapter ,publication 0)))
          (,buffer
           (cl-letf (((symbol-function 'textui--visible-width)
                      (lambda (_buffer) epub-reader-annotation-test--width)))
             (textui-open
              (generate-new-buffer-name " *epub-language-test*")
              #'epub-reader-annotation-test--frame
              (list :blocks ,blocks)))))
     (unwind-protect
         (with-current-buffer ,buffer ,@body)
       (when (buffer-live-p ,buffer) (kill-buffer ,buffer))
       (epub-reader-publication-close ,publication))))

(defun epub-reader-annotation-test--block (blocks element-id)
  "Return from BLOCKS the block identified by ELEMENT-ID."
  (cl-find element-id blocks :key #'epub-reader-block-element-id :test #'equal))

(defun epub-reader-annotation-test--source-lines (block-key)
  "Return source offset lists for physical lines belonging to BLOCK-KEY."
  (save-excursion
    (goto-char (point-min))
    (let (lines)
      (while (not (eobp))
        (let* ((start (line-beginning-position))
               (end (line-end-position))
               (offsets
                (cl-loop for position from start below end
                         for source = (get-text-property
                                       position 'epub-reader-source)
                         when (and (epub-reader-locator-source-p source)
                                   (equal (aref source 1) block-key))
                         collect (aref source 2))))
          (when offsets
            (push (list start end offsets) lines)))
        (forward-line 1))
      (nreverse lines))))

(defun epub-reader-annotation-test--position (block-key offset)
  "Return rendered position for BLOCK-KEY and source OFFSET."
  (cl-loop for position from (point-min) below (point-max)
           for source = (get-text-property position 'epub-reader-source)
           when (and (epub-reader-locator-source-p source)
                     (equal (aref source 1) block-key)
                     (= (aref source 2) offset))
           return position))

(defun epub-reader-annotation-test--records (blocks)
  "Return canonical locator records for BLOCKS."
  (cl-loop for block across blocks
           collect (list (epub-reader-block-book-key block)
                         (epub-reader-block-spine-index block)
                         (epub-reader-block-document-path block)
                         (epub-reader-block-key block)
                         (substring-no-properties
                          (epub-reader-block-text block)))))

(defun epub-reader-annotation-test--locator
    (block offset &optional schema path book-key)
  "Return a test locator for BLOCK and OFFSET."
  (epub-reader-locator--create
   :schema (or schema 3) :book-key (or book-key "book") :spine-index 0
   :path (or path "chapter.xhtml") :block block :offset offset
   :prefix "" :suffix "" :context ""))

(defun epub-reader-annotation-test--range
    (block offset exact prefix suffix &optional end-block end-offset)
  "Return a test range starting at BLOCK and OFFSET over EXACT."
  (epub-reader-locator-range--create
   :schema 1
   :start (epub-reader-annotation-test--locator block offset)
   :end (epub-reader-annotation-test--locator
         (or end-block block)
         (or end-offset (+ offset (1- (length exact)))))
   :exact exact :prefix prefix :suffix suffix))

(ert-deftest epub-reader-english-wraps-at-spaces-and-justifies-lines ()
  (epub-reader-annotation-test--with-language-buffer
      (_buffer _publication blocks)
    (let* ((block (epub-reader-annotation-test--block blocks "english"))
           (text (substring-no-properties (epub-reader-block-text block)))
           (lines (epub-reader-annotation-test--source-lines
                   (epub-reader-block-key block))))
      (should (> (length lines) 1))
      (cl-loop for line in lines
               for next in (cdr lines)
               while next
               for offsets = (nth 2 line)
               for next-offsets = (nth 2 next)
               for gap = (substring text (1+ (car (last offsets)))
                                    (car next-offsets))
               do (should (string-match-p "\\`[[:space:]]+\\'" gap))
               do (should
                   (cl-loop for position from (nth 0 line) below (nth 1 line)
                            thereis
                            (get-text-property
                             position 'textui--pixel-justified)))))))

(ert-deftest epub-reader-mixed-wrap-keeps-latin-runs-and-source-order ()
  (epub-reader-annotation-test--with-language-buffer
      (_buffer _publication blocks)
    (let* ((block (epub-reader-annotation-test--block blocks "mixed"))
           (key (epub-reader-block-key block))
           (text (substring-no-properties (epub-reader-block-text block)))
           (lines (epub-reader-annotation-test--source-lines key)))
      (should (> (length lines) 1))
      (dolist (word '("Emacs" "EPUB" "TextUI" "reader"))
        (let* ((start (string-match (regexp-quote word) text))
               (word-offsets (number-sequence start (1- (+ start (length word))))))
          (should
           (cl-some (lambda (line)
                      (cl-every (lambda (offset) (memq offset (nth 2 line)))
                                word-offsets))
                    lines))))
      (should
       (equal
        (apply #'string
               (cl-loop for line in lines append
                        (mapcar (lambda (offset) (aref text offset))
                                (nth 2 line))))
        text))
      ;; Mixed spacing is display-only: source boundaries gain no literal
      ;; spaces, while non-final mixed lines still receive justification.
      (should (string-match-p "用Emacs阅读EPUB" text))
      (dolist (line (butlast lines))
        (should
         (cl-loop for position from (nth 0 line) below (nth 1 line)
                  thereis
                  (get-text-property position 'textui--pixel-justified)))))))

(ert-deftest epub-reader-locator-range-round-trips-mixed-text-after-reflow ()
  (epub-reader-annotation-test--with-language-buffer
      (buffer _publication blocks)
    (let* ((block (epub-reader-annotation-test--block blocks "mixed"))
           (key (epub-reader-block-key block))
           (text (substring-no-properties (epub-reader-block-text block)))
           (start-offset (string-match "Emacs" text))
           (end-offset (+ (string-match "EPUB" text) (length "EPUB")))
           (start (epub-reader-annotation-test--position key start-offset))
           (end (1+ (epub-reader-annotation-test--position
                     key (1- end-offset))))
           (range (epub-reader-locator-range-capture start end 0))
           (persisted (epub-reader-locator-range-to-plist range)))
      (should (equal (epub-reader-locator-range-exact range)
                     "Emacs阅读EPUB"))
      (setq range (epub-reader-locator-range-from-plist persisted))
      (let ((epub-reader-annotation-test--width 30))
        (cl-letf (((symbol-function 'textui--visible-width)
                   (lambda (_buffer) 30)))
          (textui-refresh buffer)))
      (let ((resolution
             (epub-reader-locator-range-resolve
              range (epub-reader-annotation-test--records blocks))))
        (should (eq (epub-reader-locator-range-resolution-quality resolution)
                    'exact))
        (should (equal (epub-reader-locator-range-resolution-spans resolution)
                       (list (list key start-offset end-offset))))))))

(ert-deftest epub-reader-locator-range-captures-hidden-english-wrap-space ()
  "A visual-line selection must quote canonical source, including its space."
  (epub-reader-annotation-test--with-language-buffer
      (buffer _publication blocks)
    (let* ((block (epub-reader-annotation-test--block blocks "english"))
           (key (epub-reader-block-key block))
           (text (substring-no-properties (epub-reader-block-text block)))
           (lines (epub-reader-annotation-test--source-lines key))
           (pair
            (cl-loop for left in lines
                     for right in (cdr lines)
                     for left-last = (car (last (nth 2 left)))
                     for right-first = (car (nth 2 right))
                     when (> right-first (1+ left-last))
                     return (list left right left-last right-first)))
           (start-offset (max 0 (- (nth 2 pair) 3)))
           (end-offset (min (length text) (+ (nth 3 pair) 4)))
           (start (epub-reader-annotation-test--position key start-offset))
           (end (1+ (epub-reader-annotation-test--position
                     key (1- end-offset))))
           (range
            (epub-reader-locator-range-capture
             start end 0 buffer
             (epub-reader-annotation-test--records blocks))))
      (should pair)
      (should (string-match-p " " (substring text start-offset end-offset)))
      (should (equal (epub-reader-locator-range-exact range)
                     (substring text start-offset end-offset)))
      (let ((resolution
             (epub-reader-locator-range-resolve
              range (epub-reader-annotation-test--records blocks))))
        (should (eq (epub-reader-locator-range-resolution-quality resolution)
                    'exact))))))

(ert-deftest epub-reader-locator-range-quote-tie-prefers-original-block ()
  (let* ((records '(("book" 0 "chapter.xhtml" "b1" "xx target yy")
                    ("book" 0 "chapter.xhtml" "b2" "xxx target yy")))
         (range (epub-reader-annotation-test--range
                 "b2" 3 "target" "missing" "context"))
         (resolution (epub-reader-locator-range-resolve range records)))
    (should (eq (epub-reader-locator-range-resolution-quality resolution)
                'quote))
    (should (equal (epub-reader-locator-range-resolution-spans resolution)
                   '(("b2" 4 10))))))

(ert-deftest epub-reader-locator-range-quote-tie-can-be-ambiguous ()
  (let* ((records '(("book" 0 "chapter.xhtml" "b1" "xx target yy")
                    ("book" 0 "chapter.xhtml" "b2" "xx target yy")))
         (range (epub-reader-annotation-test--range
                 "missing" 3 "target" "missing" "context"))
         (resolution (epub-reader-locator-range-resolve range records)))
    (should (eq (epub-reader-locator-range-resolution-quality resolution)
                'ambiguous))
    (should-not (epub-reader-locator-range-resolution-spans resolution))))

(ert-deftest epub-reader-locator-range-rejects-unsupported-endpoint-schema ()
  (let* ((start (epub-reader-annotation-test--locator "b1" 0 999))
         (end (epub-reader-annotation-test--locator "b1" 5 999))
         (persisted
          (list :schema 1
                :start (epub-reader-locator-to-plist start)
                :end (epub-reader-locator-to-plist end)
                :exact "target" :prefix "" :suffix "")))
    (should-error (epub-reader-locator-range-from-plist persisted))
    (let* ((range (epub-reader-locator-range--create
                   :schema 1 :start start :end end :exact "target"
                   :prefix "" :suffix ""))
           (resolution
            (epub-reader-locator-range-resolve
             range '(("book" 0 "chapter.xhtml" "b1" "target")))))
      (should (eq (epub-reader-locator-range-resolution-quality resolution)
                  'unsupported-schema)))))

(ert-deftest epub-reader-locator-range-rejects-reversed-cross-block-endpoints ()
  "A persisted backwards range must not quote-relocate to a plausible match."
  (let* ((records '(("book" 0 "chapter.xhtml" "b1" "aaaaaa")
                    ("book" 0 "chapter.xhtml" "b2" "target")))
         (range
          (epub-reader-locator-range--create
           :schema 1
           :start (epub-reader-annotation-test--locator "b2" 0)
           :end (epub-reader-annotation-test--locator "b1" 5)
           :exact "target" :prefix "" :suffix ""))
         (decoded
          (epub-reader-locator-range-from-plist
           (epub-reader-locator-range-to-plist range)))
         (resolution
          (epub-reader-locator-range-resolve decoded records)))
    (should (eq (epub-reader-locator-range-resolution-quality resolution)
                'invalid-range))
    (should-not (epub-reader-locator-range-resolution-spans resolution))))

(ert-deftest epub-reader-locator-range-capture-normalizes-reversed-region ()
  "Interactive endpoint order is canonical even when the region is backwards."
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "Alpha" "chapter.xhtml" "b1" "book" 0))
    (insert "\n")
    (insert (epub-reader-locator-attach-source
             "Beta" "chapter.xhtml" "b2" "book" 0))
    (let* ((records '(("book" 0 "chapter.xhtml" "b1" "Alpha")
                      ("book" 0 "chapter.xhtml" "b2" "Beta")))
           (range (epub-reader-locator-range-capture
                   (point-max) (point-min) 0 nil records)))
      (should (equal (epub-reader-locator-block
                      (epub-reader-locator-range-start range))
                     "b1"))
      (should (equal (epub-reader-locator-block
                      (epub-reader-locator-range-end range))
                     "b2"))
      (should (equal (epub-reader-locator-range-exact range)
                     "AlphaBeta")))))

(ert-deftest epub-reader-locator-range-relocates-mixed-quote ()
  (epub-reader-annotation-test--with-language-buffer
      (_buffer _publication blocks)
    (let* ((block (epub-reader-annotation-test--block blocks "mixed"))
           (key (epub-reader-block-key block))
           (text (substring-no-properties (epub-reader-block-text block)))
           (start-offset (string-match "Emacs" text))
           (end-offset (+ (string-match "EPUB" text) (length "EPUB")))
           (range
            (epub-reader-locator-range-capture
             (epub-reader-annotation-test--position key start-offset)
             (1+ (epub-reader-annotation-test--position key (1- end-offset)))
             0))
           (start-locator (epub-reader-locator-range-start range))
           (changed (concat "新增开头" text))
           (records
            (list (list (epub-reader-locator-book-key start-locator) 0
                        (epub-reader-locator-path start-locator)
                        "changed-block" changed)))
           (resolution (epub-reader-locator-range-resolve range records)))
      (should (eq (epub-reader-locator-range-resolution-quality resolution)
                  'quote))
      (should
       (equal (epub-reader-locator-range-resolution-spans resolution)
              (list (list "changed-block" (+ start-offset 4)
                          (+ end-offset 4))))))))

(ert-deftest epub-reader-render-applies-mixed-highlight-with-source-anchor ()
  (let ((publication
         (epub-reader-publication-open
          (epub-reader-test-fixture "language-mix.epub"))))
    (unwind-protect
        (let* ((blocks (vconcat (epub-reader-render-chapter publication 0)))
               (block (epub-reader-annotation-test--block blocks "mixed"))
               (text (substring-no-properties (epub-reader-block-text block)))
               (start (string-match "Emacs" text))
               (end (+ (string-match "EPUB" text) (length "EPUB")))
               (element
                (epub-reader-render-block-element
                 block nil nil nil nil
                 (list (list :start start :end end :id "mixed-highlight"
                             :quality 'quote :note "混排笔记"))))
               (value (plist-get element :value)))
          (should (memq 'epub-reader-highlight-degraded-face
                        (ensure-list (get-text-property start 'face value))))
          (should (equal (get-text-property
                          start 'epub-reader-annotation-ids value)
                         '("mixed-highlight")))
          (should (string-match-p
                   "relocated" (get-text-property start 'help-echo value)))
          (should (equal (get-text-property start 'epub-reader-source value)
                         (epub-reader-locator-source
                          (epub-reader-block-document-path block)
                          (epub-reader-block-key block) start))))
      (epub-reader-publication-close publication))))

(provide 'epub-reader-annotation-test)
;;; epub-reader-annotation-test.el ends here
