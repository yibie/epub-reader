;;; epub-reader-ui-test.el --- Single-chapter reader tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-test-helper)

(defmacro epub-reader-ui-test--with-reader (binding &rest body)
  "Open the EPUB 2 fixture as buffer BINDING, run BODY, then kill it."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,binding
          (epub-reader-open (epub-reader-test-fixture "epub2.epub"))))
     (unwind-protect
         (with-current-buffer ,binding ,@body)
       (when (buffer-live-p ,binding)
         (kill-buffer ,binding)))))

(defun epub-reader-ui-test--href-position (href)
  "Return first buffer position carrying HREF."
  (cl-loop for position from (point-min) below (point-max)
           when (equal (get-text-property position 'epub-reader-href) href)
           return position))

(ert-deftest epub-reader-ui-opens-centered-textui-reader-and-cleans-up ()
  (let ((epub-reader-reading-width 32)
        root)
    (epub-reader-ui-test--with-reader buffer
      (should (derived-mode-p 'textui-mode))
      (should epub-reader-ui-mode)
      (should (eq (lookup-key epub-reader-ui-mode-map (kbd "n"))
                  #'epub-reader-next-chapter))
      (let* ((publication
              (epub-reader-session-publication epub-reader-ui--session))
             (container (epub-reader-publication-container publication))
             (source-position (epub-reader-ui--first-source-position)))
        (setq root (epub-reader-container-root container))
        (should (file-directory-p root))
        (should source-position)
        (goto-char source-position)
        (should (> (current-column) 0))))
    (should-not (file-exists-p root))))

(ert-deftest epub-reader-ui-n-and-p-switch-spine-chapters ()
  (epub-reader-ui-test--with-reader _buffer
    (should (= (plist-get textui-state :spine-index) 0))
    (epub-reader-next-chapter)
    (should (= (plist-get textui-state :spine-index) 1))
    (should (string-match-p "第二章"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))
    (epub-reader-previous-chapter)
    (should (= (plist-get textui-state :spine-index) 0))))

(ert-deftest epub-reader-ui-follows-internal-link-to-spine-fragment ()
  (epub-reader-ui-test--with-reader _buffer
    (let ((position
           (epub-reader-ui-test--href-position
            "chapter2.xhtml#second")))
      (should position)
      (should (eq (lookup-key
                   (get-text-property position 'keymap) (kbd "RET"))
                  #'epub-reader-follow-link))
      (goto-char position)
      (epub-reader-follow-link)
      (should (= (plist-get textui-state :spine-index) 1))
      (let ((source (get-text-property (point) 'epub-reader-source)))
        (should (epub-reader-locator-source-p source))
        (should (equal (aref source 0) "OEBPS/chapter2.xhtml"))
        (should (string-suffix-p ":second" (aref source 1)))))))

(ert-deftest epub-reader-ui-opens-only-allowlisted-external-links ()
  (epub-reader-ui-test--with-reader _buffer
    (let ((position (epub-reader-ui--first-source-position))
          opened)
      (let ((inhibit-read-only t))
        (put-text-property position (1+ position) 'epub-reader-href
                           "https://example.com/reader"))
      (goto-char position)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _arguments) (setq opened url))))
        (epub-reader-follow-link))
      (should (equal opened "https://example.com/reader"))
      (let ((inhibit-read-only t))
        (put-text-property position (1+ position) 'epub-reader-href
                           "javascript:alert(1)"))
      (setq opened nil)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _arguments) (setq opened url))))
        (should-error (epub-reader-follow-link)
                      :type 'epub-reader-publication-error))
      (should-not opened))))

(ert-deftest epub-reader-ui-tags-every-rendered-image-row-with-source ()
  (epub-reader-ui-test--with-reader _buffer
    (epub-reader-next-chapter)
    (let ((positions
           (cl-loop for position from (point-min) below (point-max)
                    when (get-text-property position
                                            'epub-reader-image-slice)
                    collect position))
          (image-blocks
          (cl-remove-if-not
            (lambda (block)
              (and (eq (epub-reader-block-kind block) 'image)
                   (epub-reader-block-image-file block)))
            (epub-reader-session-blocks epub-reader-ui--session))))
      (should positions)
      (should
       (equal
        (sort (delete-dups
               (mapcar
                (lambda (position)
                  (aref (get-text-property
                         position 'epub-reader-source)
                        1))
                positions))
              #'string<)
        (sort (mapcar #'epub-reader-block-key image-blocks) #'string<)))
      (goto-char (nth (/ (length positions) 2) positions))
      (let ((locator (epub-reader-locator-at-point 1)))
        (should locator)
        (should (equal (epub-reader-locator-book-key locator)
                       (epub-reader-publication-book-key
                        (epub-reader-session-publication
                         epub-reader-ui--session))))
        (should (= (epub-reader-locator-spine-index locator) 1))
        (should
         (member (epub-reader-locator-block locator)
                 (mapcar #'epub-reader-block-key image-blocks)))))))

(ert-deftest epub-reader-ui-chrome-does-not-produce-reading-locator ()
  (epub-reader-ui-test--with-reader _buffer
    (let ((chrome
           (cl-loop for position from (point-min) below (point-max)
                    when (get-text-property position 'epub-reader-chrome)
                    return position)))
      (should chrome)
      (should-not (epub-reader-locator-at-point 0 chrome)))
    (let ((first-source (epub-reader-ui--first-source-position))
          last-source)
      (cl-loop for position downfrom (1- (point-max)) to (point-min)
               when (epub-reader-locator-source-p
                     (get-text-property position 'epub-reader-source))
               return (setq last-source position))
      (should first-source)
      (should last-source)
      (cl-loop for position from (point-min) below first-source
               do (should (get-text-property position 'epub-reader-chrome))
               do (should-not (epub-reader-locator-at-point 0 position)))
      (cl-loop for position from (1+ last-source) below (point-max)
               do (should (get-text-property position 'epub-reader-chrome))
               do (should-not (epub-reader-locator-at-point 0 position)))
      (save-excursion
        (goto-char first-source)
        (let ((line-first first-source)
              (line-start (line-beginning-position))
              (line-end (line-end-position))
              line-last)
          (cl-loop for position from line-start below line-first
                   do (should
                       (get-text-property position 'epub-reader-chrome))
                   do (should-not
                       (epub-reader-locator-at-point 0 position)))
          (cl-loop for position downfrom (1- line-end) to line-first
                   when (epub-reader-locator-source-p
                         (get-text-property position 'epub-reader-source))
                   return (setq line-last position))
          (should line-last)
          (cl-loop for position from (1+ line-last) below line-end
                   do (should
                       (get-text-property position 'epub-reader-chrome))
                   do (should-not
                       (epub-reader-locator-at-point 0 position))))))))

(ert-deftest epub-reader-ui-resolves-empty-container-and-inline-fragments ()
  (let ((buffer
         (epub-reader-open (epub-reader-test-fixture "epub3-edge.epub"))))
    (unwind-protect
        (with-current-buffer buffer
          (dolist (fragment '("empty-block" "container-target"
                              "inline-target" "page-1"))
            (let ((position
                   (epub-reader-ui--fragment-position
                    "EPUB/text/a b.xhtml" fragment)))
              (should position)
              (should (equal (get-text-property
                              position 'epub-reader-anchor-id)
                             fragment)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-keeps-domain-objects-out-of-textui-state ()
  (let ((buffer
         (epub-reader-open (epub-reader-test-fixture "epub2.epub"))))
    (unwind-protect
        (with-current-buffer buffer
          (should (epub-reader-session-p epub-reader-ui--session))
          (should (epub-reader-publication-p
                   (epub-reader-session-publication
                    epub-reader-ui--session)))
          (should (hash-table-p
                   (epub-reader-session-dom-cache epub-reader-ui--session)))
          (dolist (key '(:publication :section :blocks :store :file))
            (should-not (plist-member textui-state key)))
          (should (equal (plist-get textui-state :spine-index) 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'epub-reader-ui-test)
;;; epub-reader-ui-test.el ends here
