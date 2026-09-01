;;; epub-reader-render-test.el --- Renderer and locator tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'seq)
(require 'textui)
(require 'epub-reader-render)
(require 'epub-reader-test-helper)

(defmacro epub-reader-render-test--with-publication (binding &rest body)
  "Open the EPUB 2 fixture as BINDING, evaluate BODY, then close it."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,binding
          (epub-reader-publication-open
           (epub-reader-test-fixture "epub2.epub"))))
     (unwind-protect
         (progn ,@body)
       (epub-reader-publication-close ,binding))))

(defun epub-reader-render-test--frame (_available-width)
  "Render test blocks at the width stored in `textui-state'."
  `((:type :flex
     :direction :row
     :gap 0
     :children
     ((:type :flex
       :direction :column
       :gap 1
       :layout (:width ,(plist-get textui-state :width)
                :min-width ,(plist-get textui-state :width))
       :children ,(epub-reader-render-blocks
                   (plist-get textui-state :blocks)))))))

(defun epub-reader-render-test--property-position
    (start end property expected &optional object)
  "Find PROPERTY `equal' to EXPECTED between START and END in OBJECT."
  (cl-loop for position from start below end
           when (equal (get-text-property position property object) expected)
           return position))

(ert-deftest epub-reader-render-maps-xhtml-to-semantic-blocks ()
  (epub-reader-render-test--with-publication publication
    (let ((blocks (epub-reader-render-chapter publication 0)))
      (should (equal (mapcar #'epub-reader-block-kind blocks)
                     '(heading paragraph quote paragraph)))
      (should (string-match-p
               "哲学从问题开始"
               (epub-reader-block-text (car blocks))))
      (let* ((last (car (last blocks)))
             (link-position
              (epub-reader-render-test--property-position
               0 (length (epub-reader-block-text last))
               'epub-reader-href "chapter2.xhtml#second"
               (epub-reader-block-text last))))
        (should link-position)
        (should-not
         (get-text-property link-position 'keymap
                            (epub-reader-block-text last))))
      (dolist (block blocks)
        (let ((source
               (get-text-property 0 'epub-reader-source
                                  (epub-reader-block-text block))))
          (should (epub-reader-locator-source-p source))
          (should (equal (aref source 0) "OEBPS/chapter1.xhtml")))))))

(ert-deftest epub-reader-render-maps-images-to-image-leaves-with-anchor ()
  (epub-reader-render-test--with-publication publication
    (let* ((blocks (epub-reader-render-chapter publication 1))
           (images
            (cl-remove-if-not
             (lambda (block) (eq (epub-reader-block-kind block) 'image))
             blocks))
           (image (car images))
           (element (epub-reader-render-block-element image)))
      (should image)
      (should (= (length images) 4))
      (should (= (length (delete-dups
                          (mapcar #'epub-reader-block-key images)))
                 4))
      (should
       (equal (mapcar #'epub-reader-block-key (seq-take (cdr images) 2))
              '("path:body/3:p/image:0" "path:body/3:p/image:1")))
      (should (file-readable-p (epub-reader-block-image-file image)))
      (should (eq (plist-get element :type) :flex))
      (should (eq (plist-get (car (plist-get element :children)) :type)
                  :image))
      (should
       (epub-reader-locator-source-p
        (get-text-property 0 'epub-reader-source
                           (epub-reader-block-text image)))))))

(ert-deftest epub-reader-render-preserves-list-container-and-inline-order ()
  (epub-reader-render-test--with-publication publication
    (let* ((blocks (epub-reader-render-chapter publication 1))
           (anchor-position
            (cl-position "two-images" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
           (ordered
            (cl-remove-if-not
             (lambda (block)
               (and (eq (epub-reader-block-kind block) 'list-item)
                    (string-suffix-p ". "
                                     (epub-reader-block-list-marker block))))
             blocks))
           (unknown
            (cl-find-if
             (lambda (block)
               (string-match-p
                "未知容器前中后"
                (substring-no-properties (epub-reader-block-text block))))
             blocks))
           (broken
            (cl-find-if #'epub-reader-block-image-error blocks)))
      (should anchor-position)
      (should
       (equal
        (mapcar #'epub-reader-block-kind
                (seq-subseq blocks anchor-position (+ anchor-position 6)))
        '(anchor paragraph image paragraph image paragraph)))
      (should
       (equal
        (mapcar (lambda (block)
                  (substring-no-properties (epub-reader-block-text block)))
                (seq-subseq blocks (1+ anchor-position)
                            (+ anchor-position 6)))
        '("前" "[图一]" "中" "[图二]" "后")))
      (should (equal (mapcar #'epub-reader-block-list-marker ordered)
                     '("3. " "4. ")))
      (should
       (string-prefix-p
        "3. "
        (plist-get (epub-reader-render-block-element (car ordered)) :value)))
      (should unknown)
      (should broken)
      (should (string-match-p "missing.png"
                              (epub-reader-block-image-error broken)))
      (should (string-match-p "missing.png"
                              (epub-reader-block-text broken))))))

(ert-deftest epub-reader-locator-round-trips-across-textui-reflow ()
  (epub-reader-render-test--with-publication publication
    (let* ((blocks (epub-reader-render-chapter publication 0))
           (buffer-name (generate-new-buffer-name " *epub-render-test*"))
           (buffer
            (textui-open buffer-name #'epub-reader-render-test--frame
                         (list :width 14 :blocks blocks))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((position
                   (epub-reader-render-test--property-position
                    (point-min) (point-max) 'epub-reader-source
                    (epub-reader-locator-source
                     "OEBPS/chapter1.xhtml"
                     (epub-reader-block-key (nth 1 blocks)) 5))))
              (should position)
              (goto-char position)
              (let ((locator (epub-reader-locator-at-point 0)))
                (should locator)
                (should (= (epub-reader-locator-offset locator) 5))
                (should (equal
                         (epub-reader-locator-book-key locator)
                         (epub-reader-publication-book-key publication)))
                (should (= (epub-reader-locator-spine-index locator) 0))
                (textui-set-state buffer :width 24)
                (textui-refresh buffer)
                (should (epub-reader-locator-goto locator buffer))
                (should
                 (equal
                  (get-text-property (point) 'epub-reader-source)
                  (epub-reader-locator-source
                   "OEBPS/chapter1.xhtml"
                   (epub-reader-block-key (nth 1 blocks)) 5))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest epub-reader-locator-chooses-nearest-source-not-scan-order ()
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source "前" "chapter.xhtml" "before"))
    (insert "\n\n\n\n\n\n\n\n\n\n")
    (insert (epub-reader-locator-attach-source "后" "chapter.xhtml" "after"))
    (let ((locator (epub-reader-locator-at-point 0 3)))
      (should locator)
      (should (equal (epub-reader-locator-block locator) "before")))
    (goto-char 2)
    (insert (propertize "chrome" 'epub-reader-chrome t))
    (should-not (epub-reader-locator-at-point 0 3)))
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source "甲" "chapter.xhtml" "same"))
    (insert "\u200b")
    (insert (epub-reader-locator-attach-source "乙" "chapter.xhtml" "same"))
    (let ((locator (epub-reader-locator-at-point 0 2)))
      (should (= (epub-reader-locator-offset locator) 0)))))

(ert-deftest epub-reader-render-preserves-empty-and-inline-id-anchors ()
  (let ((publication
         (epub-reader-publication-open
          (epub-reader-test-fixture "epub3-edge.epub"))))
    (unwind-protect
        (let* ((blocks (epub-reader-render-chapter publication 0))
               (empty
                (cl-find "empty-block" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (container
                (cl-find "container-target" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (page
                (cl-find "page-1" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (inline
                (cl-find-if
                 (lambda (block)
                   (cl-loop for position from 0
                            below (length (epub-reader-block-text block))
                            thereis
                            (equal
                             (get-text-property
                              position 'epub-reader-anchor-id
                              (epub-reader-block-text block))
                             "inline-target")))
                 blocks)))
          (dolist (block (list empty container page inline))
            (should block)
            (should (epub-reader-locator-source-p
                     (get-text-property
                      0 'epub-reader-source
                      (epub-reader-block-text block)))))
          (should (equal (epub-reader-block-key empty) "id:empty-block"))
          (should (equal
                   (get-text-property
                    0 'epub-reader-anchor-id (epub-reader-block-text page))
                   "page-1")))
      (epub-reader-publication-close publication))))

(ert-deftest epub-reader-render-normalizes-cjk-source-segment-breaks ()
  (let ((publication
         (epub-reader-publication-open
          (epub-reader-test-fixture "epub3-edge.epub"))))
    (unwind-protect
        (let* ((blocks (epub-reader-render-chapter publication 0))
               (cjk
                (cl-find "cjk-break" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (latin
                (cl-find "latin-break" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (japanese
                (cl-find "ja-break" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (korean
                (cl-find "ko-break" blocks
                         :key #'epub-reader-block-element-id :test #'equal)))
          (should (equal (substring-no-properties
                          (epub-reader-block-text cjk))
                         "中文，继续 甲（乙） 中 文"))
          (should (equal (substring-no-properties
                          (epub-reader-block-text latin))
                         "Hello world"))
          (should (equal (substring-no-properties
                          (epub-reader-block-text japanese))
                         "日本語"))
          (should (equal (substring-no-properties
                          (epub-reader-block-text korean))
                         "한국어 문장"))
          (should (equal
                   (get-text-property
                    0 'epub-reader-language
                    (epub-reader-block-text japanese))
                   "ja"))
          (should (equal
                   (get-text-property
                    0 'epub-reader-language
                    (epub-reader-block-text korean))
                   "ko")))
      (epub-reader-publication-close publication))))

(ert-deftest epub-reader-render-preserves-br-as-attributed-hard-break ()
  (let ((publication
         (epub-reader-publication-open
          (epub-reader-test-fixture "epub3-edge.epub"))))
    (unwind-protect
        (let* ((blocks (epub-reader-render-chapter publication 0))
               (block
                (cl-find "hard-break" blocks
                         :key #'epub-reader-block-element-id :test #'equal))
               (text (epub-reader-block-text block)))
          (should (equal (substring-no-properties text) "甲\n\n乙"))
          (should (get-text-property 1 'epub-reader-hard-break text))
          (should (get-text-property 2 'epub-reader-hard-break text))
          (should (memq 'epub-reader-strong-face
                        (ensure-list (get-text-property 3 'face text))))
          (dotimes (position (length text))
            (should (epub-reader-locator-source-p
                     (get-text-property position 'epub-reader-source text))))
          (let* ((buffer-name
                  (generate-new-buffer-name " *epub-br-render-test*"))
                 (buffer
                  (textui-open buffer-name #'epub-reader-render-test--frame
                               (list :width 40 :blocks (list block)))))
            (unwind-protect
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (should (search-forward "甲" nil t))
                  (let ((first-line (line-number-at-pos)))
                    (should (search-forward "乙" nil t))
                    (should (= (line-number-at-pos) (+ first-line 2)))
                    (should (epub-reader-locator-source-p
                             (get-text-property
                              (1- (point)) 'epub-reader-source)))))
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))))
      (epub-reader-publication-close publication))))

(ert-deftest epub-reader-locator-reports-degraded-resolution-quality ()
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "Alpha target Omega" "chapter.xhtml" "old-block" "book" 0))
    (let ((locator (epub-reader-locator-at-point 0 8)))
      (erase-buffer)
      (insert (epub-reader-locator-attach-source
               "Alpha target Omega" "chapter.xhtml" "new-block" "book" 0))
      (let ((resolution (epub-reader-locator-resolve locator)))
        (should (eq (epub-reader-locator-resolution-quality resolution)
                    'quote-in-spine))
        (should (epub-reader-locator-resolution-position resolution)))
      (setf (epub-reader-locator-block locator) "new-block"
            (epub-reader-locator-offset locator) 999)
      (should
       (eq (epub-reader-locator-resolution-quality
            (epub-reader-locator-resolve locator))
           'quote-near-block))
      (setf (epub-reader-locator-prefix locator) "missing"
            (epub-reader-locator-suffix locator) "quote"
            (epub-reader-locator-block locator) "missing-block")
      (should
       (eq (epub-reader-locator-resolution-quality
            (epub-reader-locator-resolve locator))
           'spine-start)))))

(ert-deftest epub-reader-locator-validates-quote-before-exact-resolution ()
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "Alpha target Omega" "chapter.xhtml" "id:stable" "book" 4))
    (let ((locator (epub-reader-locator-at-point 4 8)))
      (erase-buffer)
      (insert (epub-reader-locator-attach-source
               "XX Alpha target Omega" "chapter.xhtml" "id:stable"
               "book" 4))
      (let* ((resolution (epub-reader-locator-resolve locator))
             (position
              (epub-reader-locator-resolution-position resolution)))
        (should (eq (epub-reader-locator-resolution-quality resolution)
                    'quote-near-block))
        (should position)
        (should (= (aref (get-text-property
                          position 'epub-reader-source)
                         2)
                   10))))))

(ert-deftest epub-reader-locator-rejects-cross-book-and-spine-resolution ()
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "same text" "chapter.xhtml" "id:stable" "book-a" 2))
    (let ((locator (epub-reader-locator-at-point 2 3)))
      (erase-buffer)
      (insert (epub-reader-locator-attach-source
               "same text" "chapter.xhtml" "id:stable" "book-b" 2))
      (let ((resolution (epub-reader-locator-resolve locator)))
        (should-not (epub-reader-locator-resolution-position resolution))
        (should (eq (epub-reader-locator-resolution-quality resolution)
                    'identity-mismatch)))
      (erase-buffer)
      (insert (epub-reader-locator-attach-source
               "same text" "other.xhtml" "id:stable" "book-a" 2))
      (let ((resolution (epub-reader-locator-resolve locator)))
        (should-not (epub-reader-locator-resolution-position resolution))
        (should (eq (epub-reader-locator-resolution-quality resolution)
                    'identity-mismatch)))
      ;; Numeric indices change when a publisher reorders the spine.  The href
      ;; remains the durable identity and should still resolve.
      (erase-buffer)
      (insert (epub-reader-locator-attach-source
               "same text" "chapter.xhtml" "id:stable" "book-a" 9))
      (let ((resolution (epub-reader-locator-resolve locator)))
        (should (epub-reader-locator-resolution-position resolution))
        (should (eq (epub-reader-locator-resolution-quality resolution)
                    'exact))))))

(ert-deftest epub-reader-locator-rejects-legacy-publisher-only-identity ()
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "same text" "chapter.xhtml" "id:stable" "publisher-id" 0))
    (let ((locator (epub-reader-locator-at-point 0 3)))
      (setf (epub-reader-locator-schema locator) 2)
      (let ((resolution (epub-reader-locator-resolve locator)))
        (should-not (epub-reader-locator-resolution-position resolution))
        (should (eq (epub-reader-locator-resolution-quality resolution)
                    'legacy-identity))))))

(ert-deftest epub-reader-locator-separates-fixtures-with-shared-identifier ()
  (let ((first
         (epub-reader-publication-open
          (epub-reader-test-fixture "shared-identifier-a.epub")))
        (second
         (epub-reader-publication-open
          (epub-reader-test-fixture "shared-identifier-b.epub"))))
    (unwind-protect
        (with-temp-buffer
          (should (equal (epub-reader-publication-identifier first)
                         (epub-reader-publication-identifier second)))
          (insert (epub-reader-block-text
                   (car (epub-reader-render-chapter first 0))))
          (let ((locator (epub-reader-locator-at-point 0 (point-min))))
            (erase-buffer)
            (insert (epub-reader-block-text
                     (car (epub-reader-render-chapter second 0))))
            (let ((resolution (epub-reader-locator-resolve locator)))
              (should-not
               (epub-reader-locator-resolution-position resolution))
              (should
               (eq (epub-reader-locator-resolution-quality resolution)
                   'identity-mismatch)))))
      (epub-reader-publication-close second)
      (epub-reader-publication-close first))))

(provide 'epub-reader-render-test)
;;; epub-reader-render-test.el ends here
