;;; epub-reader-render-test.el --- Renderer and locator tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
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
        (should
         (keymapp
          (get-text-property link-position 'keymap
                             (epub-reader-block-text last)))))
      (dolist (block blocks)
        (let ((source
               (get-text-property 0 'epub-reader-source
                                  (epub-reader-block-text block))))
          (should (epub-reader-locator-source-p source))
          (should (equal (aref source 0) "OEBPS/chapter1.xhtml")))))))

(ert-deftest epub-reader-render-maps-images-to-image-leaves-with-anchor ()
  (epub-reader-render-test--with-publication publication
    (let* ((blocks (epub-reader-render-chapter publication 1))
           (image (cl-find 'image blocks :key #'epub-reader-block-kind))
           (element (epub-reader-render-block-element image)))
      (should image)
      (should (file-readable-p (epub-reader-block-image-file image)))
      (should (eq (plist-get element :type) :flex))
      (should (eq (plist-get (car (plist-get element :children)) :type)
                  :image))
      (should
       (epub-reader-locator-source-p
        (get-text-property 0 'epub-reader-source
                           (epub-reader-block-text image)))))))

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

(ert-deftest epub-reader-locator-reports-degraded-resolution-quality ()
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "Alpha target Omega" "chapter.xhtml" "old-block"))
    (let ((locator (epub-reader-locator-at-point 0 8)))
      (erase-buffer)
      (insert (epub-reader-locator-attach-source
               "Alpha target Omega" "chapter.xhtml" "new-block"))
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

(provide 'epub-reader-render-test)
;;; epub-reader-render-test.el ends here
