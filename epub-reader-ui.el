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

(defcustom epub-reader-chunk-max-blocks 64
  "Maximum semantic blocks materialized in one chapter chunk."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-chunk-max-characters 24000
  "Maximum normalized source characters in one chapter chunk.
A single larger block is still materialized by itself."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-chunk-guard-blocks 8
  "Block distance from a chunk edge that triggers a chunk shift."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-chunk-overscan-screens 3
  "Approximate screen heights kept around the active semantic block."
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

(cl-defstruct (epub-reader-session
               (:constructor epub-reader-session--create))
  "Non-UI state owned by one reader buffer."
  publication section blocks block-index anchor-index dom-cache store
  refreshing-p producer-block-count)

(cl-defstruct (epub-reader-chapter-data
               (:constructor epub-reader-chapter-data--create))
  "Cached parsed and normalized data for one spine document."
  section blocks block-index anchor-index character-count)

(cl-defstruct (epub-reader-viewport
               (:constructor epub-reader-viewport--create))
  "One window's semantic position and relative logical row."
  window locator row)

(cl-defstruct (epub-reader-view-state
               (:constructor epub-reader-view-state--create))
  "Semantic point plus all live window viewport records."
  point-locator viewports)

(defvar-local epub-reader-ui--session nil
  "Domain session owned by the current EPUB reader buffer.")

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
  (if epub-reader-ui-mode
      (progn
        (setq-local truncate-lines nil)
        (add-hook 'post-command-hook
                  #'epub-reader-ui--maybe-shift-chunk nil t))
    (remove-hook 'post-command-hook
                 #'epub-reader-ui--maybe-shift-chunk t)))

(defun epub-reader-ui--state-value (key)
  "Return KEY from the current reader's TextUI state."
  (unless (and (derived-mode-p 'textui-mode) epub-reader-ui-mode)
    (user-error "Not in an EPUB reader buffer"))
  (plist-get textui-state key))

(defun epub-reader-ui--current-session ()
  "Return the current reader session or signal a user-facing error."
  (unless (epub-reader-session-p epub-reader-ui--session)
    (user-error "EPUB reader session is unavailable"))
  epub-reader-ui--session)

(defun epub-reader-ui--chapter-cache-key (publication index)
  "Return the cache key for PUBLICATION spine INDEX."
  (let ((resource
         (epub-reader-publication-spine-resource publication index)))
    (unless resource
      (signal 'args-out-of-range
              (list index (length
                           (epub-reader-publication-spine publication)))))
    (list (epub-reader-publication-book-key publication)
          (epub-reader-resource-path resource))))

(defun epub-reader-ui--index-blocks (blocks)
  "Return (BLOCK-INDEX ANCHOR-INDEX CHARACTER-COUNT) for BLOCKS vector."
  (let ((block-index (make-hash-table :test #'equal))
        (anchor-index (make-hash-table :test #'equal))
        (characters 0))
    (cl-loop for block across blocks
             for index from 0
             do (puthash (epub-reader-block-key block) index block-index)
             when (epub-reader-block-element-id block)
             do (puthash (epub-reader-block-element-id block)
                         index anchor-index)
             do (setq characters
                      (+ characters (length (epub-reader-block-text block)))))
    (list block-index anchor-index characters)))

(defun epub-reader-ui--load-chapter (session index)
  "Load spine INDEX into SESSION, reusing its normalized chapter cache."
  (let* ((publication (epub-reader-session-publication session))
         (key (epub-reader-ui--chapter-cache-key publication index))
         (cache (epub-reader-session-dom-cache session))
         (chapter (gethash key cache)))
    (unless chapter
      (let* ((section
              (epub-reader-publication-load-section publication index))
             (blocks
              (vconcat (epub-reader-render-section publication section)))
             (indices (epub-reader-ui--index-blocks blocks)))
        (setq chapter
              (epub-reader-chapter-data--create
               :section section :blocks blocks
               :block-index (nth 0 indices) :anchor-index (nth 1 indices)
               :character-count (nth 2 indices)))
        (puthash key chapter cache)))
    (setf (epub-reader-session-section session)
          (epub-reader-chapter-data-section chapter)
          (epub-reader-session-blocks session)
          (epub-reader-chapter-data-blocks chapter)
          (epub-reader-session-block-index session)
          (epub-reader-chapter-data-block-index chapter)
          (epub-reader-session-anchor-index session)
          (epub-reader-chapter-data-anchor-index chapter))
    chapter))

(defun epub-reader-ui--minimum-window-height ()
  "Return the smallest live body height displaying the current buffer."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows
        (apply #'min (mapcar #'window-body-height windows))
      20)))

(defun epub-reader-ui--overscan-blocks ()
  "Return the current approximate overscan in semantic blocks."
  (max epub-reader-chunk-guard-blocks
       (min (max 1 (/ epub-reader-chunk-max-blocks 2))
            (* epub-reader-chunk-overscan-screens
               (epub-reader-ui--minimum-window-height)))))

(defun epub-reader-ui--chunk-end (blocks start)
  "Return exclusive chunk end in BLOCKS from START under both budgets."
  (let ((end start)
        (characters 0)
        (length (length blocks)))
    (while (and (< end length)
                (< (- end start) epub-reader-chunk-max-blocks)
                (or (= end start)
                    (<= (+ characters
                           (length (epub-reader-block-text (aref blocks end))))
                        epub-reader-chunk-max-characters)))
      (setq characters
            (+ characters
               (length (epub-reader-block-text (aref blocks end))))
            end (1+ end)))
    end))

(defun epub-reader-ui--chunk-range (blocks target-index)
  "Return a budgeted (START END) range in BLOCKS containing TARGET-INDEX."
  (let* ((length (length blocks))
         (target (max 0 (min target-index (max 0 (1- length)))))
         (start (max 0 (- target (epub-reader-ui--overscan-blocks))))
         (end (epub-reader-ui--chunk-end blocks start)))
    (when (>= target end)
      (setq start target
            end (epub-reader-ui--chunk-end blocks start)))
    (list start end)))

(defun epub-reader-ui--state-with-chunk (state start end)
  "Return copied STATE with chapter chunk START and END."
  (let ((next (copy-sequence state)))
    (setq next (plist-put next :chunk-start start))
    (plist-put next :chunk-end end)))

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

(defun epub-reader-ui--centered-column (available-width children &optional gap)
  "Return CHILDREN in a centered reading column within AVAILABLE-WIDTH."
  (let* ((column-width
          (max 1 (min available-width (max 1 epub-reader-reading-width))))
         (remaining (max 0 (- available-width column-width)))
         (left (/ remaining 2))
         (right (- remaining left))
         (column
          (list :type :flex :direction :column :gap (or gap 0)
                :layout (list :width column-width :min-width column-width)
                :children children))
         row)
    (when (> left 0)
      (push (epub-reader-ui--spacer left) row))
    (push column row)
    (when (> right 0)
      (push (epub-reader-ui--spacer right) row))
    (list :type :flex :direction :row :gap 0
          :children (nreverse row))))

(defun epub-reader-ui--chapter-elements (available-width)
  "Return the current budgeted chapter region at AVAILABLE-WIDTH."
  (let* ((session (epub-reader-ui--current-session))
         (blocks (epub-reader-session-blocks session))
         (start (or (plist-get textui-state :chunk-start) 0))
         (end (or (plist-get textui-state :chunk-end) (length blocks)))
         elements)
    (cl-loop for index from start below (min end (length blocks))
             do (push (epub-reader-render-block-element (aref blocks index))
                      elements))
    (setf (epub-reader-session-producer-block-count session)
          (length elements))
    (list (epub-reader-ui--centered-column
           available-width (nreverse elements) 1))))

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

(defun epub-reader-ui--post-render (&optional buffer)
  "Install EPUB interaction and source metadata after rendering BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (epub-reader-locator-tag-image-runs (current-buffer))
    (epub-reader-ui--attach-link-actions (current-buffer))
    (epub-reader-ui--mark-chrome-regions (current-buffer)))
  nil)

(defun epub-reader-ui--mark-chrome-regions (&optional buffer)
  "Mark all frame chrome, including TextUI-synthesized cells, in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (let ((position (point-min))
            first-source last-source
            (inhibit-read-only t))
        (while (< position (point-max))
          (when (epub-reader-locator-source-p
                 (get-text-property position 'epub-reader-source))
            (unless first-source
              (setq first-source position))
            (setq last-source position))
          (setq position (1+ position)))
        (when first-source
          (add-text-properties
           (point-min) first-source '(epub-reader-chrome t))
          (add-text-properties
           (1+ last-source) (point-max) '(epub-reader-chrome t))
          (goto-char first-source)
          (while (<= (line-beginning-position) last-source)
            (let ((line-start (line-beginning-position))
                  (line-end (line-end-position))
                  line-first line-last)
              (setq position line-start)
              (while (< position line-end)
                (when (epub-reader-locator-source-p
                       (get-text-property position 'epub-reader-source))
                  (unless line-first
                    (setq line-first position))
                  (setq line-last position))
                (setq position (1+ position)))
              (when line-first
                (add-text-properties
                 line-start line-first '(epub-reader-chrome t))
                (add-text-properties
                 (1+ line-last) line-end '(epub-reader-chrome t))))
            (forward-line 1))))))
  nil)

(defun epub-reader-ui-frame (available-width)
  "Return the complete reader frame for AVAILABLE-WIDTH."
  (let* ((session (epub-reader-ui--current-session))
         (publication (epub-reader-session-publication session))
         (index (plist-get textui-state :spine-index))
         (start (plist-get textui-state :chunk-start))
         (end (plist-get textui-state :chunk-end)))
    (textui-effect
     'epub-reader-post-render (list index start end available-width)
     (lambda ()
       (epub-reader-ui--post-render (current-buffer))))
    (list
     (list
      :type :flex :direction :column :gap 1
      :children
      (list
       (epub-reader-ui--centered-column
        available-width (list (epub-reader-ui--header publication index)))
       (list :type :flex :direction :column :gap 0
             :layout '(:refresh-id chapter)
             :children (epub-reader-ui--chapter-elements available-width))
       (epub-reader-ui--centered-column
        available-width (list (epub-reader-ui--footer))))))))

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

(defun epub-reader-ui--capture-view-state ()
  "Capture current semantic point and relative rows of visible windows."
  (let ((index (epub-reader-ui--state-value :spine-index))
        viewports)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (when (window-live-p window)
        (let ((window-point (window-point window)))
          (push
           (epub-reader-viewport--create
            :window window
            :locator (epub-reader-locator-at-point
                      index window-point (current-buffer))
            :row (max 0 (- (line-number-at-pos window-point)
                           (line-number-at-pos (window-start window)))))
           viewports))))
    (epub-reader-view-state--create
     :point-locator (epub-reader-locator-at-point index)
     :viewports (nreverse viewports))))

(defun epub-reader-ui--restore-view-state (view-state)
  "Restore semantic point and window rows from VIEW-STATE after refresh."
  (let ((point-locator
         (epub-reader-view-state-point-locator view-state)))
    (when point-locator
      (let ((position (epub-reader-locator-point point-locator)))
        (when position (goto-char position))))
    (dolist (viewport (epub-reader-view-state-viewports view-state))
      (let* ((window (epub-reader-viewport-window viewport))
             (locator (epub-reader-viewport-locator viewport))
             (position (and locator (epub-reader-locator-point locator))))
        (when (and position (window-live-p window)
                   (eq (window-buffer window) (current-buffer)))
          (set-window-point window position)
          (save-excursion
            (goto-char position)
            (forward-line (- (epub-reader-viewport-row viewport)))
            (set-window-start window (line-beginning-position) t)))))))

(defun epub-reader-ui--refresh-chunk (start end)
  "Synchronously replace the chapter region with block range START to END."
  (let* ((session (epub-reader-ui--current-session))
         (view-state (epub-reader-ui--capture-view-state))
         (buffer (current-buffer)))
    (unless (epub-reader-session-refreshing-p session)
      (setf (epub-reader-session-refreshing-p session) t)
      (unwind-protect
          (progn
            ;; `textui-state' is documented render state.  Region refresh is
            ;; synchronous so semantic restoration can happen after commit.
            (setq textui-state
                  (epub-reader-ui--state-with-chunk textui-state start end))
            (textui-refresh-region
             buffer 'chapter #'epub-reader-ui--chapter-elements)
            (epub-reader-ui--post-render buffer)
            (epub-reader-ui--restore-view-state view-state))
        (setf (epub-reader-session-refreshing-p session) nil)))
    buffer))

(defun epub-reader-ui--ensure-block-visible (block-index)
  "Refresh the current chunk if needed to include BLOCK-INDEX."
  (let* ((blocks
          (epub-reader-session-blocks (epub-reader-ui--current-session)))
         (start (plist-get textui-state :chunk-start))
         (end (plist-get textui-state :chunk-end)))
    (unless (and (<= start block-index) (< block-index end))
      (pcase-let ((`(,next-start ,next-end)
                   (epub-reader-ui--chunk-range blocks block-index)))
        (epub-reader-ui--refresh-chunk next-start next-end)))))

(defun epub-reader-ui--maybe-shift-chunk ()
  "Shift the chapter window when point approaches a rendered chunk edge."
  (when (and epub-reader-ui-mode
             (epub-reader-session-p epub-reader-ui--session)
             (not (epub-reader-session-refreshing-p epub-reader-ui--session)))
    (let* ((index (epub-reader-ui--state-value :spine-index))
           (locator (epub-reader-locator-at-point index))
           (block-index
            (and locator
                 (gethash
                  (epub-reader-locator-block locator)
                  (epub-reader-session-block-index epub-reader-ui--session))))
           (start (plist-get textui-state :chunk-start))
           (end (plist-get textui-state :chunk-end))
           (length (length
                    (epub-reader-session-blocks epub-reader-ui--session))))
      (when (and block-index
                 (or (and (> start 0)
                          (< (- block-index start)
                             epub-reader-chunk-guard-blocks))
                     (and (< end length)
                          (<= (- end block-index)
                              epub-reader-chunk-guard-blocks))))
        (pcase-let ((`(,next-start ,next-end)
                     (epub-reader-ui--chunk-range
                      (epub-reader-session-blocks epub-reader-ui--session)
                      block-index)))
          (unless (and (= start next-start) (= end next-end))
            (epub-reader-ui--refresh-chunk next-start next-end)))))))

(defun epub-reader-ui--goto-start (&optional fragment)
  "Move to current chapter's FRAGMENT or first source position."
  (let* ((session (epub-reader-ui--current-session))
         (section (epub-reader-session-section session))
         (block-index (and fragment
                           (gethash fragment
                                    (epub-reader-session-anchor-index session))))
         (_visible (when block-index
                     (epub-reader-ui--ensure-block-visible block-index)))
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
         (session (epub-reader-ui--current-session))
         (publication (epub-reader-session-publication session))
         (count (length (epub-reader-publication-spine publication))))
    (unless (and (>= index 0) (< index count))
      (user-error "No chapter in that direction"))
    (let* ((_chapter (epub-reader-ui--load-chapter session index))
           (target (or (and fragment
                            (gethash
                             fragment
                             (epub-reader-session-anchor-index session)))
                       0))
           (range
            (epub-reader-ui--chunk-range
             (epub-reader-session-blocks session) target)))
      (textui-update
       buffer
       (lambda (state)
         (let ((next (copy-sequence state)))
           (setq next (plist-put next :spine-index index))
           (epub-reader-ui--state-with-chunk
            next (car range) (cadr range)))))
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
    (let* ((session (epub-reader-ui--current-session))
           (publication (epub-reader-session-publication session))
           (current-index (epub-reader-ui--state-value :spine-index))
           (section (epub-reader-session-section session))
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
              (let* ((block-index
                      (and (epub-reader-link-target-fragment target)
                           (gethash
                            (epub-reader-link-target-fragment target)
                            (epub-reader-session-anchor-index session))))
                     (_visible
                      (when block-index
                        (epub-reader-ui--ensure-block-visible block-index)))
                     (position
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
        (session nil)
        (buffer nil)
        succeeded)
    (unwind-protect
        (progn
          (setq publication (epub-reader-publication-open file))
          (let* ((_session
                  (setq session
                        (epub-reader-session--create
                         :publication publication
                         :dom-cache (make-hash-table :test #'equal)
                         :store nil)))
                 (_chapter (epub-reader-ui--load-chapter session 0))
                 (range
                  (epub-reader-ui--chunk-range
                   (epub-reader-session-blocks session) 0))
                 (name
                  (generate-new-buffer-name
                   (format "*EPUB: %s*"
                           (epub-reader-publication-title publication)))))
            ;; Supply the session to the initial render, then install the same
            ;; object as the buffer-local owner immediately after `textui-open'.
            (let ((epub-reader-ui--session session))
              (setq buffer
                    (textui-open
                     name #'epub-reader-ui-frame
                     (list :spine-index 0 :chunk-start (car range)
                           :chunk-end (cadr range)
                           :loading nil :error nil
                           :pending-locator nil)))))
          (with-current-buffer buffer
            (setq-local epub-reader-ui--session session)
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
          (ignore-errors (epub-reader-publication-close publication)))))))

(provide 'epub-reader-ui)
;;; epub-reader-ui.el ends here
