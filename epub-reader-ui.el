;;; epub-reader-ui.el --- Single-chapter TextUI EPUB reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (textui "0.5.1"))

;;; Commentary:

;; This is the first vertical reader slice: a centered chapter frame, width
;; reflow delegated to TextUI, internal/external links, and spine navigation.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'subr-x)
(require 'textui)
(require 'epub-reader-locator)
(require 'epub-reader-publication)
(require 'epub-reader-render)

(defcustom epub-reader-reading-width 76
  "Preferred width in character cells of the centered reading column."
  :type 'integer
  :group 'epub-reader)

(defface epub-reader-header-face
  '((t (:inherit shadow :weight semibold)))
  "Face for the publication and chapter header."
  :group 'epub-reader)

(defface epub-reader-footer-face
  '((t (:inherit shadow :height 0.9)))
  "Face for the reader key-hint footer."
  :group 'epub-reader)

(defvar-keymap epub-reader-ui-mode-map
  :doc "Keymap active in EPUB reader TextUI buffers."
  "n" #'epub-reader-next-chapter
  "p" #'epub-reader-previous-chapter
  "RET" #'epub-reader-follow-link
  "q" #'epub-reader-quit)

(defvar epub-reader-ui-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'epub-reader-follow-link)
    (define-key map [mouse-1] #'epub-reader-follow-link-mouse)
    map)
  "Keymap installed by the UI on rendered EPUB hyperlink runs.")

(define-minor-mode epub-reader-ui-mode
  "Minor mode adding EPUB reader commands to a TextUI buffer."
  :init-value nil
  :lighter " EPUB"
  :keymap epub-reader-ui-mode-map
  (when epub-reader-ui-mode
    (setq-local truncate-lines nil)))

(defun epub-reader-ui--state-value (key)
  "Return KEY from the current reader's TextUI state."
  (unless (and (derived-mode-p 'textui-mode) epub-reader-ui-mode)
    (user-error "Not in an EPUB reader buffer"))
  (plist-get textui-state key))

(defun epub-reader-ui--spacer (width)
  "Return a fixed native spacer element of WIDTH cells."
  (list :type 'item :format "%v"
        :value (propertize (make-string width ?\s) 'epub-reader-chrome t)
        :layout (list :width width)))

(defun epub-reader-ui--header (publication index)
  "Return header TextUI element for PUBLICATION spine INDEX."
  (let ((count (length (epub-reader-publication-spine publication))))
    (list :type :text
          :value
          (propertize
           (format "%s  ·  %d/%d"
                   (epub-reader-publication-title publication)
                   (1+ index) count)
           'face 'epub-reader-header-face
           'epub-reader-chrome t))))

(defun epub-reader-ui--footer ()
  "Return the first-release reader key hint."
  (list :type :text
        :value (propertize
                "n 下一章  ·  p 上一章  ·  RET 打开链接  ·  q 关闭"
                'face 'epub-reader-footer-face 'epub-reader-chrome t)))

(defun epub-reader-ui--attach-link-actions (&optional buffer)
  "Install UI-owned interaction properties on hyperlink runs in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let ((position (point-min))
          (inhibit-read-only t))
      (while (< position (point-max))
        (let* ((href (get-text-property position 'epub-reader-href))
               (end
                (or (next-single-property-change
                     position 'epub-reader-href nil (point-max))
                    (point-max))))
          (when href
            (add-text-properties
             position end
             (list 'help-echo href 'mouse-face 'highlight 'follow-link t
                   'keymap epub-reader-ui-link-map)))
          (setq position end)))))
  nil)

(defun epub-reader-ui-frame (available-width)
  "Return the complete reader frame for AVAILABLE-WIDTH."
  (let* ((publication (plist-get textui-state :publication))
         (index (plist-get textui-state :spine-index))
         (blocks (plist-get textui-state :blocks))
         (column-width
          (max 1 (min available-width
                      (max 1 epub-reader-reading-width))))
         (remaining (max 0 (- available-width column-width)))
         (left (/ remaining 2))
         (right (- remaining left))
         (column
          (list :type :flex :direction :column :gap 1
                :layout (list :width column-width
                              :min-width column-width)
                :children
                (append
                 (list (epub-reader-ui--header publication index))
                 (epub-reader-render-blocks blocks)
                 (list (epub-reader-ui--footer)))))
         children)
    (textui-effect
     'epub-reader-post-render (list index available-width)
     (lambda ()
       (epub-reader-locator-tag-image-runs (current-buffer))
       (epub-reader-ui--attach-link-actions (current-buffer))))
    (when (> left 0)
      (push (epub-reader-ui--spacer left) children))
    (push column children)
    (when (> right 0)
      (push (epub-reader-ui--spacer right) children))
    (list
     (list :type :flex :direction :row :gap 0
           :children (nreverse children)))))

(defun epub-reader-ui--first-source-position ()
  "Return the first source-backed position in the current buffer."
  (let ((position (point-min)))
    (while (and (< position (point-max))
                (not (epub-reader-locator-source-p
                      (get-text-property position 'epub-reader-source))))
      (setq position
            (or (next-single-property-change
                 position 'epub-reader-source nil (point-max))
                (point-max))))
    (and (< position (point-max)) position)))

(defun epub-reader-ui--fragment-position (path fragment)
  "Return source position for FRAGMENT in document PATH."
  (when fragment
    (let ((position (point-min))
          (suffix (concat ":" fragment))
          found)
      (while (and (< position (point-max)) (not found))
        (let ((source (get-text-property position 'epub-reader-source))
              (anchor (get-text-property position 'epub-reader-anchor-id)))
          (when (and (epub-reader-locator-source-p source)
                     (equal (aref source 0) path)
                     (or (equal anchor fragment)
                         (string-suffix-p suffix (aref source 1))))
            (setq found position)))
        (unless found
          (setq position
                (or (next-single-property-change
                     position 'epub-reader-source nil (point-max))
                    (point-max)))))
      found)))

(defun epub-reader-ui--recenter-visible-windows ()
  "Place point at the top of every live window showing current buffer."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p window)
      (set-window-point window (point))
      (with-selected-window window
        (recenter 0)))))

(defun epub-reader-ui--goto-start (&optional fragment)
  "Move to current chapter's FRAGMENT or first source position."
  (let* ((section (epub-reader-ui--state-value :section))
         (position
          (or (epub-reader-ui--fragment-position
               (epub-reader-section-path section) fragment)
              (epub-reader-ui--first-source-position)
              (point-min))))
    (goto-char position)
    (epub-reader-ui--recenter-visible-windows)))

(defun epub-reader-ui--switch-chapter (index &optional fragment)
  "Synchronously switch the current reader to spine INDEX and FRAGMENT."
  (let* ((buffer (current-buffer))
         (publication (epub-reader-ui--state-value :publication))
         (count (length (epub-reader-publication-spine publication))))
    (unless (and (>= index 0) (< index count))
      (user-error "No chapter in that direction"))
    (let* ((section
            (epub-reader-publication-load-section publication index))
           (blocks (epub-reader-render-section publication section)))
      (textui-update
       buffer
       (lambda (state)
         (let ((next (copy-sequence state)))
           (setq next (plist-put next :spine-index index))
           (setq next (plist-put next :section section))
           (plist-put next :blocks blocks))))
      (textui-refresh buffer)
      (epub-reader-ui--goto-start fragment)
      buffer)))

(defun epub-reader-next-chapter ()
  "Move to the next spine document."
  (interactive)
  (epub-reader-ui--switch-chapter
   (1+ (epub-reader-ui--state-value :spine-index))))

(defun epub-reader-previous-chapter ()
  "Move to the previous spine document."
  (interactive)
  (epub-reader-ui--switch-chapter
   (1- (epub-reader-ui--state-value :spine-index))))

(defun epub-reader-ui--href-at-point ()
  "Return EPUB href text property at or immediately before point."
  (or (get-text-property (point) 'epub-reader-href)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'epub-reader-href))))

(defun epub-reader-ui--spine-index-for-path (publication path)
  "Return zero-based PUBLICATION spine index whose resource has PATH."
  (cl-loop for item across (epub-reader-publication-spine publication)
           for index from 0
           when (equal
                 (epub-reader-resource-path
                  (epub-reader-spine-item-resource item))
                 path)
           return index))

(defun epub-reader-follow-link ()
  "Follow the EPUB hyperlink at point."
  (interactive)
  (let ((href (epub-reader-ui--href-at-point)))
    (unless href
      (user-error "No EPUB link at point"))
    (let* ((publication (epub-reader-ui--state-value :publication))
           (current-index (epub-reader-ui--state-value :spine-index))
           (section (epub-reader-ui--state-value :section))
           (target
            (epub-reader-publication-resolve-resource
             publication section href)))
      (if (epub-reader-link-target-external-p target)
          (browse-url (epub-reader-link-target-uri target))
        (let ((index
               (epub-reader-ui--spine-index-for-path
                publication (epub-reader-link-target-path target))))
          (unless index
            (user-error "Linked document is not in the reading spine: %s"
                        (epub-reader-link-target-path target)))
          (if (= index current-index)
              (let ((position
                     (epub-reader-ui--fragment-position
                      (epub-reader-link-target-path target)
                      (epub-reader-link-target-fragment target))))
                (unless position
                  (user-error "Link fragment was not found: %s" href))
                (goto-char position)
                (epub-reader-ui--recenter-visible-windows))
            (epub-reader-ui--switch-chapter
             index (epub-reader-link-target-fragment target))))))))

(defun epub-reader-follow-link-mouse (event)
  "Move to mouse EVENT and follow its EPUB hyperlink."
  (interactive "e")
  (mouse-set-point event)
  (epub-reader-follow-link))

(defun epub-reader-quit ()
  "Close the current EPUB reader buffer and release its publication."
  (interactive)
  (kill-buffer (current-buffer)))

(defun epub-reader-ui-open (file)
  "Open EPUB FILE in a new TextUI reader buffer and return that buffer."
  (let ((publication nil)
        (buffer nil)
        succeeded)
    (unwind-protect
        (progn
          (setq publication (epub-reader-publication-open file))
          (let* ((section
                  (epub-reader-publication-load-section publication 0))
                 (blocks
                  (epub-reader-render-section publication section))
                 (name
                  (generate-new-buffer-name
                   (format "*EPUB: %s*"
                           (epub-reader-publication-title publication)))))
            (setq buffer
                  (textui-open
                   name #'epub-reader-ui-frame
                   (list :publication publication
                         :spine-index 0
                         :section section
                         :blocks blocks
                         :file (expand-file-name file)))))
          (with-current-buffer buffer
            (epub-reader-ui-mode 1)
            (setq-local buffer-file-name nil)
            (setq-local default-directory
                        (file-name-directory (expand-file-name file))))
          (textui-register-cleanup
           buffer (lambda ()
                    (epub-reader-publication-close publication)))
          (with-current-buffer buffer
            (epub-reader-ui--goto-start))
          (setq succeeded t)
          buffer)
      (unless succeeded
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when publication
          (epub-reader-publication-close publication))))))

(provide 'epub-reader-ui)
;;; epub-reader-ui.el ends here
