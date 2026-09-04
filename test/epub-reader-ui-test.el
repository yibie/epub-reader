;;; epub-reader-ui-test.el --- Single-chapter reader tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-test-helper)

(defmacro epub-reader-ui-test--with-reader (binding &rest body)
  "Open the EPUB 2 fixture as buffer BINDING, run BODY, then kill it."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
         (epub-reader-first-paint-max-characters
          epub-reader-chunk-max-characters)
         ,binding)
     (setq ,binding
           (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
     (unwind-protect
         (with-current-buffer ,binding ,@body)
       (when (buffer-live-p ,binding)
         (kill-buffer ,binding)))))

(defun epub-reader-ui-test--materialize-current-images ()
  "Run the deferred image job for the active test chapter."
  (epub-reader-ui--background-image-job
   epub-reader-ui--session (plist-get textui-state :spine-index)
   (plist-get textui-state :chunk-start)
   (plist-get textui-state :chunk-end)))

(defun epub-reader-ui-test--href-position (href)
  "Return first buffer position carrying HREF."
  (cl-loop for position from (point-min) below (point-max)
           when (equal (get-text-property position 'epub-reader-href) href)
           return position))

(defun epub-reader-ui-test--block-position (key)
  "Return first rendered source position whose semantic block has KEY."
  (cl-loop for position from (point-min) below (point-max)
           for source = (get-text-property position 'epub-reader-source)
           when (and (epub-reader-locator-source-p source)
                     (equal (aref source 1) key))
           return position))

(defun epub-reader-ui-test--source-position (key offset)
  "Return rendered position for semantic block KEY at source OFFSET."
  (cl-loop for position from (point-min) below (point-max)
           for source = (get-text-property position 'epub-reader-source)
           when (and (epub-reader-locator-source-p source)
                     (equal (aref source 1) key)
                     (= (aref source 2) offset))
           return position))

(defun epub-reader-ui-test--property-count (property)
  "Return the number of distinct non-nil PROPERTY values in this buffer."
  (length
   (delete-dups
    (cl-loop for position from (point-min) below (point-max)
             for value = (get-text-property position property)
             when value collect value))))

(defun epub-reader-ui-test--source-lines (block-key)
  "Return canonical offsets painted on each physical line for BLOCK-KEY."
  (save-excursion
    (goto-char (point-min))
    (let (lines)
      (while (not (eobp))
        (let ((offsets
               (cl-loop for position from (line-beginning-position)
                        below (line-end-position)
                        for source = (get-text-property
                                      position 'epub-reader-source)
                        when (and (epub-reader-locator-source-p source)
                                  (equal (aref source 1) block-key))
                        collect (aref source 2))))
          (when offsets (push offsets lines)))
        (forward-line 1))
      (nreverse lines))))

(defun epub-reader-ui-test--visual-row (window)
  "Return WINDOW point's visual row relative to its start."
  (count-screen-lines (window-start window) (window-point window)
                      nil window))

(defun epub-reader-ui-test--drain-background (session)
  "Run SESSION's queued background jobs synchronously, then disarm it."
  (while (epub-reader-session-background-jobs session)
    (epub-reader-ui--run-background-job
     session (epub-reader-session-background-generation session)))
  (epub-reader-ui--cancel-background-work session))

(defun epub-reader-ui-test--chunk-width ()
  "Return the number of semantic blocks in the current rendered chunk."
  (- (plist-get textui-state :chunk-end)
     (plist-get textui-state :chunk-start)))

(defun epub-reader-ui-test--chunk-source-characters ()
  "Return source characters represented by the current rendered chunk."
  (let ((blocks (epub-reader-ui--current-blocks))
        (start (plist-get textui-state :chunk-start))
        (end (plist-get textui-state :chunk-end)))
    (cl-loop for index from start below end
             sum (length (epub-reader-block-text (aref blocks index))))))

(defun epub-reader-ui-test--assert-page-motion (before after direction)
  "Assert a screen-sized move from BEFORE to AFTER in DIRECTION when resolvable."
  (when (and before after)
    (let ((before-position (epub-reader-locator-point before))
          (after-position (epub-reader-locator-point after)))
      (should before-position)
      (should after-position)
      (pcase direction
        ('forward (should (< before-position after-position)))
        ('backward (should (< after-position before-position))))
      ;; Reader rows carry line spacing, so a 21-row window contains about
      ;; ten physical TextUI lines.  A third of the body height distinguishes
      ;; page motion from the former one-paragraph edge fallback.
      (should
       (>= (count-screen-lines
            (min before-position after-position)
            (max before-position after-position)
            nil (selected-window))
           (/ (window-body-height (selected-window)) 3))))))

(defun epub-reader-ui-test--native-image-line-p (position)
  "Return non-nil when the physical line at POSITION contains an image slice."
  (save-excursion
    (goto-char position)
    (let ((cursor (line-beginning-position))
          (end (line-end-position))
          found)
      (while (and (< cursor end) (not found))
        (let ((display (get-text-property cursor 'display)))
          (when (and (consp display)
                     (consp (car display))
                     (eq (caar display) 'slice))
            (setq found t)))
        (setq cursor (1+ cursor)))
      found)))

(defun epub-reader-ui-test--pixel-row-height (window position)
  "Return the graphical row height at POSITION in WINDOW."
  (set-window-start window position t)
  (set-window-point window position)
  (redisplay t)
  (let* ((next
          (save-excursion
            (goto-char position)
            (forward-line 1)
            (point)))
         (current-y (cdr (posn-x-y (posn-at-point position window))))
         (next-y (cdr (posn-x-y (posn-at-point next window)))))
    (- next-y current-y)))

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
    (epub-reader-ui-test--materialize-current-images)
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
            (epub-reader-ui--current-blocks))))
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

(ert-deftest epub-reader-ui-image-slices-cannot-be-captured-as-text-highlight ()
  (epub-reader-ui-test--with-reader _buffer
    (epub-reader-next-chapter)
    (epub-reader-ui-test--materialize-current-images)
    (let ((position
           (cl-loop for cursor from (point-min) below (point-max)
                    when (get-text-property cursor 'epub-reader-image-slice)
                    return cursor)))
      (should position)
      (should-error
       (epub-reader-locator-range-capture position (1+ position) 1)
       :type 'user-error))))

(ert-deftest epub-reader-ui-image-slices-disable-line-spacing ()
  (let ((saved-default (default-value 'line-spacing))
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        buffer)
    (unwind-protect
        (progn
          (set-default 'line-spacing 0.25)
          (setq buffer
                (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
          (with-current-buffer buffer
            (should (= line-spacing 0))
            (should (local-variable-p 'line-spacing))
            (should (= epub-reader-ui--prose-line-spacing 0.25))
            (epub-reader-next-chapter)
            (epub-reader-ui-test--materialize-current-images)
            (let ((positions
                   (cl-loop for position from (point-min) below (point-max)
                            when (get-text-property
                                  position 'epub-reader-image-slice)
                            collect position)))
              (should positions)
              (dolist (position positions)
                (let ((newline
                       (save-excursion
                         (goto-char position)
                         (line-end-position))))
                  (should (< newline (point-max)))
                  (should (eq (get-text-property newline 'line-height) t))
                  (should-not
                   (get-text-property newline 'line-spacing))
                  (should-not
                   (get-text-property position 'line-spacing))))
              (let ((prose
                     (cl-loop for position from (point-min) below (point-max)
                              when (and
                                    (get-text-property
                                     position 'epub-reader-source)
                                    (not (get-text-property
                                          position
                                          'epub-reader-image-slice)))
                              return position)))
                (should prose)
                (should-not
                 (get-text-property prose 'line-spacing))
                (let ((newline
                       (save-excursion
                         (goto-char prose)
                         (line-end-position))))
                  (should-not
                   (get-text-property newline 'line-height))
                  (should (= (get-text-property newline 'line-spacing)
                             0.25)))))))
      (set-default 'line-spacing saved-default)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-image-row-pixels-exclude-prose-line-spacing ()
  (unless (display-graphic-p)
    (ert-skip "Requires a graphical frame for pixel row measurement"))
  (let ((saved-default (default-value 'line-spacing))
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        buffer)
    (unwind-protect
        (progn
          (set-default 'line-spacing 0.25)
          (setq buffer
                (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
          (with-current-buffer buffer
            (epub-reader-next-chapter)
            (epub-reader-ui-test--materialize-current-images)
            (redisplay t)
            (let* ((window (get-buffer-window buffer t))
                   (image
                    (cl-loop for position from (point-min) below (point-max)
                             when (and
                                   (get-text-property
                                    position 'epub-reader-image-slice)
                                   (epub-reader-ui-test--native-image-line-p
                                    position))
                             return (save-excursion
                                      (goto-char position)
                                      (line-beginning-position))))
                   (prose
                    (save-excursion
                      (goto-char (point-min))
                      (search-forward "这是第二章。")
                      (line-beginning-position)))
                   (image-height
                    (epub-reader-ui-test--pixel-row-height window image))
                   (prose-height
                    (epub-reader-ui-test--pixel-row-height window prose))
                   no-spacing-height)
              (let ((was-local (local-variable-p 'line-spacing))
                    (saved line-spacing))
                (setq-local line-spacing nil)
                (setq no-spacing-height
                      (epub-reader-ui-test--pixel-row-height window image))
                (if was-local
                    (setq-local line-spacing saved)
                  (kill-local-variable 'line-spacing)))
              (should (= image-height no-spacing-height))
              (should (> prose-height image-height)))))
      (set-default 'line-spacing saved-default)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-letterboxed-image-range-excludes-caption ()
  (unless (display-graphic-p)
    (ert-skip "Requires native SVG rendering in a graphical frame"))
  (epub-reader-ui-test--with-reader _buffer
    (epub-reader-next-chapter)
    (epub-reader-ui-test--materialize-current-images)
    (redisplay t)
    (goto-char (point-min))
    (let (caption-start)
      (while (and (not caption-start)
                  (search-forward "[测试封面]" nil t))
        (let ((candidate (- (point) (length "[测试封面]"))))
          ;; The first occurrence is alternative text hidden beneath the
          ;; native image display.  The later plain-text occurrence is the
          ;; separate caption produced by the reader.
          (unless (epub-reader-ui-test--native-image-line-p candidate)
            (setq caption-start candidate))))
      (should caption-start)
      (should-not
       (get-text-property caption-start 'epub-reader-image-slice)))))

(ert-deftest epub-reader-ui-text-scale-reflows-and-remeasures-image-rows ()
  (epub-reader-ui-test--with-reader _buffer
    (epub-reader-next-chapter)
    (epub-reader-ui-test--materialize-current-images)
    (let* ((real-refresh (symbol-function 'textui-refresh))
           (before-position (epub-reader-ui--first-source-position))
           (refreshes 0))
      (goto-char before-position)
      (let ((before-locator
             (epub-reader-locator-to-plist
              (epub-reader-ui--current-locator))))
        (cl-letf
            (((symbol-function 'window-font-height)
              (lambda (&optional window _face)
                (* 2 (frame-char-height
                      (window-frame (or window (selected-window)))))))
             ((symbol-function 'textui-refresh)
              (lambda (buffer)
                (setq refreshes (1+ refreshes))
                (funcall real-refresh buffer))))
          (text-scale-set 2))
        (should (= refreshes 1))
        (should
         (equal before-locator
                (epub-reader-locator-to-plist
                 (epub-reader-ui--current-locator))))
        (let* ((position
                (cl-loop for cursor from (point-min) below (point-max)
                         when (get-text-property
                               cursor 'epub-reader-image-anchor)
                         return cursor))
               (anchor
                (and position
                     (get-text-property position
                                        'epub-reader-image-anchor))))
          (should anchor)
          (should (= (nth 1 anchor) (/ epub-reader-image-rows 2))))))))

(ert-deftest epub-reader-ui-does-not-soft-wrap-textui-physical-lines ()
  (epub-reader-ui-test--with-reader _buffer
    (should truncate-lines)
    (should (equal (assq 'truncation fringe-indicator-alist)
                   '(truncation nil nil)))
    (should (equal (assq 'continuation fringe-indicator-alist)
                   '(continuation nil nil)))
    (should (eq (display-table-slot buffer-display-table 'truncation) ?\s))
    (should (eq (display-table-slot buffer-display-table 'wrap) ?\s))))

(ert-deftest epub-reader-ui-secondary-lists-hide-line-end-indicators ()
  (dolist (mode '(epub-reader-toc-mode
                  epub-reader-bookmark-list-mode
                  epub-reader-annotation-list-mode))
    (with-temp-buffer
      (funcall mode 1)
      (should truncate-lines)
      (should (equal (assq 'truncation fringe-indicator-alist)
                     '(truncation nil nil)))
      (should (equal (assq 'continuation fringe-indicator-alist)
                     '(continuation nil nil)))
      (should (eq (display-table-slot buffer-display-table 'truncation) ?\s))
      (should (eq (display-table-slot buffer-display-table 'wrap) ?\s)))))

(ert-deftest epub-reader-ui-materializes-images-only-in-current-chunk ()
  (let ((epub-reader-first-paint-max-blocks 3)
        (epub-reader-chunk-max-blocks 3))
    (epub-reader-ui-test--with-reader _buffer
      (let* ((publication
              (epub-reader-session-publication epub-reader-ui--session))
             (root
              (epub-reader-container-root
               (epub-reader-publication-container publication)))
             (image (expand-file-name "OEBPS/cover.svg" root)))
        (should-not (file-exists-p image))
        (epub-reader-next-chapter)
        (should-not (file-exists-p image))
        (epub-reader-ui--background-image-job
         epub-reader-ui--session 1
         (plist-get textui-state :chunk-start)
         (plist-get textui-state :chunk-end))
        (should (file-readable-p image))
        (should (= (plist-get textui-state :chunk-end) 3))
        (cl-loop for block across (epub-reader-ui--current-blocks)
                 for index from 0
                 when (equal (epub-reader-block-image-href block) "cover.svg")
                 if (< index 3)
                 do (should
                     (equal (epub-reader-block-image-file block) image))
                 else
                 do (should-not (epub-reader-block-image-file block)))
        (let ((broken
               (cl-find-if
                (lambda (block)
                  (equal (epub-reader-block-image-href block) "missing.png"))
                (append (epub-reader-ui--current-blocks) nil))))
          (should broken)
          (should-not (epub-reader-block-image-error broken)))))))

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
  (let ((epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        buffer)
    (setq buffer
          (epub-reader-open (epub-reader-test-fixture "epub3-edge.epub")))
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
          (should (epub-reader-chapter-data-p
                   (epub-reader-session-current-chapter
                    epub-reader-ui--session)))
          (dolist (accessor '(epub-reader-session-section
                              epub-reader-session-blocks
                              epub-reader-session-block-index
                              epub-reader-session-anchor-index))
            (should-not (fboundp accessor)))
          (dolist (key '(:publication :section :blocks :store :file))
            (should-not (plist-member textui-state key)))
          (should (equal (plist-get textui-state :spine-index) 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-long-chapter-materializes-only-budgeted-chunk ()
  (let ((epub-reader-first-paint-max-blocks 32)
        (epub-reader-first-paint-max-characters 4000)
        (epub-reader-scroll-chunk-max-blocks 32)
        (epub-reader-scroll-chunk-max-characters 4000)
        (epub-reader-chunk-max-blocks 32)
        (epub-reader-chunk-max-characters 4000)
        (rendered-leaves 0)
        buffer)
    (setq buffer
          (epub-reader-open (epub-reader-test-fixture "long-chapter.epub")))
    (unwind-protect
        (with-current-buffer buffer
          (should (= (length (epub-reader-ui--current-blocks))
                     10001))
          (should (<= (epub-reader-session-producer-block-count
                       epub-reader-ui--session)
                      epub-reader-chunk-max-blocks))
          (should (<= (- (plist-get textui-state :chunk-end)
                         (plist-get textui-state :chunk-start))
                      epub-reader-chunk-max-blocks))
          (let* ((blocks (epub-reader-ui--current-blocks))
                 (outside (aref blocks
                                (+ (plist-get textui-state :chunk-end) 100)))
                 (text (epub-reader-block-text outside)))
            (dotimes (offset (length text))
              (should-not
               (get-text-property offset 'epub-reader-source text))))
          (let ((characters 0))
            (cl-loop
             for index from (plist-get textui-state :chunk-start)
             below (plist-get textui-state :chunk-end)
             do (setq characters
                      (+ characters
                         (length
                          (epub-reader-block-text
                           (aref (epub-reader-ui--current-blocks)
                                 index)))))
             finally
             (should (<= characters epub-reader-chunk-max-characters))))
          (let* ((old-start (plist-get textui-state :chunk-start))
                 (edge-index (1- (plist-get textui-state :chunk-end)))
                 (edge-key
                  (epub-reader-block-key
                   (aref (epub-reader-ui--current-blocks)
                         edge-index)))
                 (edge-position
                  (epub-reader-ui-test--block-position edge-key)))
            (should edge-position)
            (goto-char edge-position)
            (epub-reader-ui--maybe-shift-chunk)
            (should (> (plist-get textui-state :chunk-start) old-start)))
          (let ((real-render
                 (symbol-function 'epub-reader-render-block-element)))
            (cl-letf (((symbol-function 'epub-reader-render-block-element)
                       (lambda (&rest arguments)
                         (setq rendered-leaves (1+ rendered-leaves))
                         (apply real-render arguments))))
              (epub-reader-ui--goto-start "p09999")))
          (should (<= rendered-leaves epub-reader-chunk-max-blocks))
          (should (> (plist-get textui-state :chunk-start) 9900))
          (should (equal (get-text-property
                          (point) 'epub-reader-anchor-id)
                         "p09999")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-default-scroll-crosses-long-chunk-edges ()
  "Real page commands keep useful bounded chunks across both long fixtures."
  (let ((epub-reader-enable-progress nil)
        (epub-reader-background-idle-delay 3600))
    (dolist (fixture '("long-chapter.epub" "wrapped-chapter.epub"))
      (let ((buffer (epub-reader-open (epub-reader-test-fixture fixture))))
        (unwind-protect
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer buffer)
              (with-current-buffer buffer
                (should (= (window-body-height (selected-window)) 21))
                (epub-reader-ui-test--drain-background
                 epub-reader-ui--session)
                (should (= (plist-get textui-state :chunk-start) 0))
                (should (= (plist-get textui-state :chunk-end) 64))
                (let ((steps 0)
                      (page-samples 0))
                  (while (and (<= (plist-get textui-state :chunk-end) 64)
                              (< steps 80))
                    (let ((before
                           (epub-reader-ui--locator-at-reading-row
                            0 (window-start (selected-window)))))
                      (epub-reader-scroll-forward)
                      (let ((after
                             (epub-reader-ui--locator-at-reading-row
                              0 (window-start (selected-window)))))
                        (when (and before after)
                          (setq page-samples (1+ page-samples)))
                        (epub-reader-ui-test--assert-page-motion
                         before after 'forward)))
                    (should (> (epub-reader-ui-test--chunk-width) 2))
                    (should
                     (<= (epub-reader-ui-test--chunk-width)
                         epub-reader-chunk-max-blocks))
                    (setq steps (1+ steps)))
                  (should (< steps 80))
                  (should (> page-samples 3))
                  (should (> (plist-get textui-state :chunk-start) 0))
                  (should (> (plist-get textui-state :chunk-end) 64))
                  (should-not
                   (cl-some
                    (lambda (job) (eq (car job) 'expand))
                    (epub-reader-session-background-jobs
                     epub-reader-ui--session)))
                  (let ((forward-start
                         (plist-get textui-state :chunk-start))
                        (backward-steps 0))
                    (while (and (>= (plist-get textui-state :chunk-start)
                                    forward-start)
                                (< backward-steps 80))
                      (let ((before
                             (epub-reader-ui--locator-at-reading-row
                              0 (window-start (selected-window)))))
                        (epub-reader-scroll-backward)
                        (let ((after
                               (epub-reader-ui--locator-at-reading-row
                                0 (window-start (selected-window)))))
                          (epub-reader-ui-test--assert-page-motion
                           before after 'backward)))
                      (should (> (epub-reader-ui-test--chunk-width) 2))
                      (setq backward-steps (1+ backward-steps)))
                    (should (< backward-steps 80))
                    (should (< (plist-get textui-state :chunk-start)
                               forward-start))))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest epub-reader-ui-full-chunk-shift-renders-only-entering-blocks ()
  "A settled long-chapter viewport must reuse its overlapping keyed blocks."
  (let ((epub-reader-enable-progress nil)
        (epub-reader-background-idle-delay 3600)
        buffer)
    (setq buffer
          (epub-reader-open (epub-reader-test-fixture "long-chapter.epub")))
    (unwind-protect
        (with-current-buffer buffer
          (epub-reader-ui-test--drain-background epub-reader-ui--session)
          (should (= (epub-reader-ui-test--chunk-width) 64))
          (let ((rendered 0)
                (original
                 (symbol-function 'textui-keyed-region--render-item)))
            (cl-letf (((symbol-function 'textui-keyed-region--render-item)
                       (lambda (element width)
                         (setq rendered (1+ rendered))
                         (funcall original element width))))
              (epub-reader-ui--refresh-chunk 4 68))
            (should (= rendered 4)))
          (should (= (plist-get textui-state :chunk-start) 4))
          (should (= (plist-get textui-state :chunk-end) 68)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-first-paint-uses-the-interactive-budget ()
  (let ((epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks 4)
        (epub-reader-first-paint-max-characters 1200)
        (epub-reader-chunk-max-blocks 32)
        (epub-reader-chunk-max-characters 4000)
        buffer)
    (setq buffer
          (epub-reader-open (epub-reader-test-fixture "long-chapter.epub")))
    (unwind-protect
        (with-current-buffer buffer
          (should (<= (epub-reader-session-producer-block-count
                       epub-reader-ui--session)
                      4))
          (should (<= (- (plist-get textui-state :chunk-end)
                         (plist-get textui-state :chunk-start))
                      4))
          (let ((range
                 (epub-reader-ui--chunk-range
                  (epub-reader-ui--current-blocks) 20 'scroll)))
            (should (<= (- (cadr range) (car range))
                        epub-reader-scroll-chunk-max-blocks))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-restore-materializes-forward-first-paint-chunk ()
  "Restore paints its target and following context before later expansion."
  (let ((directory (make-temp-file "epub-reader-restore-chunk-" t))
        (epub-reader-enable-progress t)
        (epub-reader-background-idle-delay 3600)
        (epub-reader-first-paint-max-blocks 4)
        (epub-reader-first-paint-max-characters 60)
        (epub-reader-chunk-max-blocks 32)
        (epub-reader-chunk-max-characters 4000)
        (file (epub-reader-test-fixture "long-chapter.epub"))
        (target-index 80)
        target-key reader)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open file))
          (with-current-buffer reader
            (setq target-key
                  (epub-reader-block-key
                   (aref (epub-reader-ui--current-blocks) target-index)))
            (epub-reader-ui--goto-block-index target-index)
            (epub-reader-ui--observe-progress t)
            (epub-reader-ui--save-progress t))
          (kill-buffer reader)
          (setq reader (epub-reader-open file))
          (with-current-buffer reader
            (let* ((session epub-reader-ui--session)
                   (start (plist-get textui-state :chunk-start))
                   (end (plist-get textui-state :chunk-end))
                   (first-width (epub-reader-ui-test--chunk-width))
                   (before (epub-reader-ui--current-locator)))
              (should (eq (plist-get textui-state :restore-quality) 'exact))
              (should (= start target-index))
              (should (equal (epub-reader-locator-block before) target-key))
              (should (<= first-width epub-reader-first-paint-max-blocks))
              ;; This fixture reaches the character budget before the block
              ;; budget, proving that both first-paint limits participate.
              (should (< first-width epub-reader-first-paint-max-blocks))
              (should (<= (epub-reader-ui-test--chunk-source-characters)
                          epub-reader-first-paint-max-characters))
              ;; The target is the first block, with forward context available.
              (should (> end (1+ start)))
              (should
               (cl-some (lambda (job) (eq (car job) 'expand))
                        (epub-reader-session-background-jobs session)))
              ;; The deferred pass is independently bounded by the normal
              ;; steady-state budgets and preserves the restored locator.
              (epub-reader-ui--background-expand-job session 0)
              (should (> (epub-reader-ui-test--chunk-width) first-width))
              (should (<= (epub-reader-ui-test--chunk-width)
                          epub-reader-chunk-max-blocks))
              (should (<= (epub-reader-ui-test--chunk-source-characters)
                          epub-reader-chunk-max-characters))
              (let ((after (epub-reader-ui--current-locator)))
                (should (equal (epub-reader-locator-block before)
                               (epub-reader-locator-block after)))
                (should (= (epub-reader-locator-offset before)
                           (epub-reader-locator-offset after)))))))
      (when (buffer-live-p reader)
        (kill-buffer reader))
      (delete-directory directory t))))

(ert-deftest epub-reader-ui-wrapped-open-restore-is-mode-independent ()
  "Wrapped progress survives Lisp callers and historical wrapper locators."
  (let ((directory (make-temp-file "epub-reader-wrapped-restore-" t))
        (epub-reader-enable-progress t)
        (epub-reader-open-full-frame nil)
        (epub-reader-background-idle-delay 3600)
        (epub-reader-first-paint-max-blocks 4)
        (epub-reader-first-paint-max-characters 1200)
        (file (epub-reader-test-fixture "wrapped-chapter.epub"))
        (target-key "id:section-p-080")
        healthy-count target-index reader)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          ;; Establish the healthy shape from a neutral caller, then perform
          ;; the complete public open/save/kill/reopen path from Lisp mode.
          (with-temp-buffer
            (fundamental-mode)
            (setq reader (epub-reader-open file)))
          (with-current-buffer reader
            (setq healthy-count (length (epub-reader-ui--current-blocks)))
            (should (= healthy-count 162)))
          (kill-buffer reader)
          (setq reader nil)
          (with-temp-buffer
            (emacs-lisp-mode)
            (setq reader (epub-reader-open file)))
          (with-current-buffer reader
            (should (= (length (epub-reader-ui--current-blocks))
                       healthy-count))
            (setq target-index
                  (gethash target-key
                           (epub-reader-ui--current-block-index
                            epub-reader-ui--session)))
            (should target-index)
            (epub-reader-ui--goto-block-index target-index)
            (epub-reader-ui--observe-progress t)
            (epub-reader-ui--save-progress t))
          (kill-buffer reader)
          (setq reader nil)
          (with-temp-buffer
            (emacs-lisp-mode)
            (setq reader (epub-reader-open file)))
          (with-current-buffer reader
            (should (= (length (epub-reader-ui--current-blocks))
                       healthy-count))
            (should (eq (plist-get textui-state :restore-quality) 'exact))
            (should (equal (epub-reader-locator-block
                            (epub-reader-ui--current-locator))
                           target-key))
            (should (= (plist-get textui-state :chunk-start) target-index)))
          (kill-buffer reader)
          (setq reader nil)
          ;; Simulate a locator written by the historical renderer, where the
          ;; section wrapper swallowed all descendant paragraphs into one key.
          (let* ((publication (epub-reader-publication-open file))
                 (store
                  (epub-reader-store-open
                   file (epub-reader-publication-book-key publication)))
                 (locator (epub-reader-store-load-locator store)))
            (should locator)
            (should-not
             (string-empty-p
              (concat (or (epub-reader-locator-prefix locator) "")
                      (or (epub-reader-locator-suffix locator) ""))))
            (setf (epub-reader-locator-block locator)
                  "path:body/0:section")
            (epub-reader-store-stage store locator)
            (epub-reader-store-close store)
            (epub-reader-publication-close publication))
          (with-temp-buffer
            (emacs-lisp-mode)
            (setq reader (epub-reader-open file)))
          (with-current-buffer reader
            (should (= (length (epub-reader-ui--current-blocks))
                       healthy-count))
            (should-not
             (gethash "path:body/0:section"
                      (epub-reader-ui--current-block-index
                       epub-reader-ui--session)))
            (should (eq (plist-get textui-state :restore-quality)
                        'quote-in-spine))
            (should (equal (epub-reader-locator-block
                            (epub-reader-ui--current-locator))
                           target-key))
            (should (= (plist-get textui-state :chunk-start) target-index))))
      (when (buffer-live-p reader)
        (kill-buffer reader))
      (delete-directory directory t))))

(ert-deftest epub-reader-ui-chapter-switch-defers-image-materialization ()
  (let ((epub-reader-enable-progress nil)
        (resolutions 0)
        (real-resolve
         (symbol-function 'epub-reader-publication-resolve-resource))
        buffer)
    (setq buffer (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function
                      'epub-reader-publication-resolve-resource)
                     (lambda (&rest arguments)
                       (setq resolutions (1+ resolutions))
                       (apply real-resolve arguments))))
            (epub-reader-next-chapter))
          (should (= resolutions 0))
          (should
           (cl-some (lambda (block)
                      (and (eq (epub-reader-block-kind block) 'image)
                           (null (epub-reader-block-image-file block))))
                    (append (epub-reader-ui--current-blocks) nil))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-chunk-refresh-requeues-deferred-images ()
  "A later viewport shift must not strand its image placeholders."
  (let ((epub-reader-enable-progress nil)
        (epub-reader-background-idle-delay 3600)
        buffer)
    (setq buffer (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((session epub-reader-ui--session))
            (epub-reader-ui--cancel-background-work session)
            (epub-reader-ui--refresh-chunk 0 1)
            (should
             (equal (epub-reader-session-background-jobs session)
                    '((images 0 0 1))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-prefetch-caches-without-changing-current-chapter ()
  (let ((epub-reader-enable-progress nil)
        (buffer (epub-reader-open (epub-reader-test-fixture "epub2.epub"))))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((session epub-reader-ui--session)
                 (current (epub-reader-session-current-chapter session)))
            (should-not
             (gethash (epub-reader-ui--chapter-cache-key
                       (epub-reader-session-publication session) 1)
                      (epub-reader-session-dom-cache session)))
            (epub-reader-ui--prefetch-chapter session 1)
            (should (eq current
                        (epub-reader-session-current-chapter session)))
            (should
             (gethash (epub-reader-ui--chapter-cache-key
                       (epub-reader-session-publication session) 1)
                      (epub-reader-session-dom-cache session)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-chunk-effects-ignore-chunk-range ()
  (epub-reader-ui-test--with-reader _buffer
    (let (effects)
      (cl-letf (((symbol-function 'textui-effect)
                 (lambda (key dependencies setup)
                   (push (list key dependencies setup) effects))))
        (epub-reader-ui-frame 71))
      (should
       (equal (cadr (assq 'epub-reader-post-render effects))
              '(0 71)))
      (let ((dependencies
             (cadr (assq 'epub-reader-background effects))))
        (should (= (length dependencies) 1))
        (should (stringp (car dependencies)))))))

(ert-deftest epub-reader-ui-narrow-window-keeps-chapter-region-refreshable ()
  (epub-reader-ui-test--with-reader buffer
    (cl-letf (((symbol-function 'textui--visible-width)
               (lambda (_buffer) 9)))
      (should (eq (textui-refresh buffer) buffer))
      (should (assq 'chapter textui--refresh-regions))
      (should (epub-reader-ui--first-source-position))
      (should (eq (epub-reader-ui--refresh-chunk 0 1) buffer))
      (should (epub-reader-ui--first-source-position)))))

(ert-deftest epub-reader-ui-chunk-guards-are-inclusive-and-symmetric ()
  (let ((epub-reader-chunk-guard-blocks 8))
    (should (epub-reader-ui--inside-chunk-guard-p 108 100 132 200))
    (should (epub-reader-ui--inside-chunk-guard-p 124 100 132 200))
    (should-not (epub-reader-ui--inside-chunk-guard-p 109 100 132 200))
    (should-not (epub-reader-ui--inside-chunk-guard-p 123 100 132 200)))
  (let ((epub-reader-chunk-guard-blocks 0))
    (should (epub-reader-ui--inside-chunk-guard-p 100 100 132 200))
    (should-not (epub-reader-ui--inside-chunk-guard-p 131 100 132 200))))

(ert-deftest epub-reader-ui-chunk-shift-preserves-visual-rows-in-two-windows ()
  (let ((epub-reader-chunk-max-blocks 32)
        (epub-reader-chunk-max-characters 4000)
        (buffer
         (epub-reader-open (epub-reader-test-fixture "long-chapter.epub"))))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buffer)
          (let ((second (split-window-right)))
            (set-window-buffer second buffer)
            (with-current-buffer buffer
              (epub-reader-ui--goto-start "p00020")
              (let* ((key "id:p00020")
                     (position
                      (cl-loop
                       for candidate from (point-min) below (point-max)
                       for source = (get-text-property
                                     candidate 'epub-reader-source)
                       when (and (epub-reader-locator-source-p source)
                                 (equal (aref source 1) key)
                                 (= (aref source 2) 800))
                       return candidate)))
                (should position)
                (dolist (entry (list (cons (selected-window) 4)
                                     (cons second 8)))
                  (with-selected-window (car entry)
                    (goto-char position)
                    (set-window-point (car entry) position)
                    (recenter (cdr entry))))
                (redisplay t)
                (let ((before
                       (mapcar
                        (lambda (window)
                          (cons (epub-reader-ui-test--visual-row window)
                                (epub-reader-locator-at-point
                                 0 (window-point window) buffer)))
                        (list (selected-window) second)))
                      (end (epub-reader-ui--chunk-end
                            (epub-reader-ui--current-blocks)
                            10)))
                  (epub-reader-ui--refresh-chunk 10 end)
                  (redisplay t)
                  (cl-mapc
                   (lambda (expected window)
                     (let ((actual
                            (epub-reader-locator-at-point
                             0 (window-point window) buffer)))
                       (should (= (car expected)
                                  (epub-reader-ui-test--visual-row window)))
                       (should (equal
                                (epub-reader-locator-block (cdr expected))
                                (epub-reader-locator-block actual)))
                       (should (= (epub-reader-locator-offset (cdr expected))
                                  (epub-reader-locator-offset actual)))))
                   before (list (selected-window) second)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-chunk-shift-restores-locator-and-window-row ()
  (let ((epub-reader-first-paint-max-blocks 32)
        (epub-reader-first-paint-max-characters 4000)
        (epub-reader-chunk-max-blocks 32)
        (epub-reader-chunk-max-characters 4000)
        buffer)
    (setq buffer
          (epub-reader-open (epub-reader-test-fixture "long-chapter.epub")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (with-current-buffer buffer
            (let* ((block
                    (aref (epub-reader-ui--current-blocks)
                          20))
                   (key (epub-reader-block-key block))
                   (position (epub-reader-ui-test--block-position key)))
              (should position)
              (goto-char position)
              (recenter 3)
              (redisplay t)
              (let* ((before (epub-reader-locator-at-point 0))
                     (before-row
                      (epub-reader-ui-test--visual-row (selected-window)))
                     (end
                      (epub-reader-ui--chunk-end
                       (epub-reader-ui--current-blocks)
                       10)))
                (epub-reader-ui--refresh-chunk 10 end)
                (redisplay t)
                (let ((after (epub-reader-locator-at-point 0))
                      (after-row
                       (epub-reader-ui-test--visual-row
                        (selected-window))))
                  (should (equal (epub-reader-locator-block before)
                                 (epub-reader-locator-block after)))
                  (should (= (epub-reader-locator-offset before)
                             (epub-reader-locator-offset after)))
                  (should (= before-row after-row)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-interactive-chunk-shift-preserves-semantic-point ()
  "The guard-triggered fast path must not change locator or progress."
  (let ((epub-reader-enable-progress nil)
        (epub-reader-background-idle-delay 3600)
        (epub-reader-first-paint-max-blocks 2)
        (epub-reader-first-paint-max-characters 4000)
        (epub-reader-scroll-chunk-max-blocks 1)
        (epub-reader-scroll-chunk-max-characters 3000)
        (epub-reader-chunk-guard-blocks 8)
        buffer)
    (setq buffer
          (epub-reader-open (epub-reader-test-fixture "long-chapter.epub")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (with-current-buffer buffer
            (epub-reader-ui--cancel-background-work epub-reader-ui--session)
            (let* ((block (aref (epub-reader-ui--current-blocks) 1))
                   (key (epub-reader-block-key block))
                   (position
                    (cl-loop
                     for candidate from (point-min) below (point-max)
                     for source = (get-text-property
                                   candidate 'epub-reader-source)
                     when (and (epub-reader-locator-source-p source)
                               (equal (aref source 1) key)
                               (= (aref source 2) 20))
                     return candidate)))
              (should position)
              (goto-char position)
              (recenter 3)
              (redisplay t)
              (let ((before (epub-reader-ui--current-locator))
                    (before-percent (epub-reader-ui--progress-percent))
                    (before-end (plist-get textui-state :chunk-end))
                    (before-row
                     (epub-reader-ui-test--visual-row (selected-window))))
                (should (= (plist-get textui-state :chunk-start) 0))
                (epub-reader-ui--maybe-shift-chunk)
                (redisplay t)
                (let ((after (epub-reader-ui--current-locator)))
                  (should (= (plist-get textui-state :chunk-start) 0))
                  (should (> (plist-get textui-state :chunk-end) before-end))
                  (should (> (epub-reader-ui-test--chunk-width) 2))
                  (should
                   (cl-some
                    (lambda (job) (eq (car job) 'expand))
                    (epub-reader-session-background-jobs
                     epub-reader-ui--session)))
                  (should (equal (epub-reader-locator-block before)
                                 (epub-reader-locator-block after)))
                  (should (= (epub-reader-locator-offset before)
                             (epub-reader-locator-offset after)))
                  (should (= before-percent
                             (epub-reader-ui--progress-percent)))
                  (should (= before-row
                             (epub-reader-ui-test--visual-row
                              (selected-window)))))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-ui-history-back-and-forward-use-locators ()
  (epub-reader-ui-test--with-reader _buffer
    (let ((origin (epub-reader-ui--current-locator)))
      (epub-reader-next-chapter)
      (let ((destination (epub-reader-ui--current-locator)))
        (should (= (plist-get textui-state :spine-index) 1))
        (epub-reader-history-back)
        (should (= (plist-get textui-state :spine-index) 0))
        (should (equal (epub-reader-locator-path
                        (epub-reader-ui--current-locator))
                       (epub-reader-locator-path origin)))
        (epub-reader-history-forward)
        (should (= (plist-get textui-state :spine-index) 1))
        (should (equal (epub-reader-locator-path
                        (epub-reader-ui--current-locator))
                       (epub-reader-locator-path destination)))))))

(ert-deftest epub-reader-ui-scroll-crosses-chapter-boundaries ()
  (epub-reader-ui-test--with-reader _buffer
    (goto-char (point-max))
    (cl-letf (((symbol-function 'scroll-up-command)
               (lambda (&rest _arguments) (signal 'end-of-buffer nil))))
      (epub-reader-scroll-forward))
    (should (= (plist-get textui-state :spine-index) 1))
    (goto-char (point-min))
    (cl-letf (((symbol-function 'scroll-down-command)
               (lambda (&rest _arguments)
                 (signal 'beginning-of-buffer nil))))
      (epub-reader-scroll-backward))
    (should (= (plist-get textui-state :spine-index) 0))
    (should (equal (epub-reader-locator-path
                    (epub-reader-ui--current-locator))
                   "OEBPS/chapter1.xhtml"))))

(ert-deftest epub-reader-ui-toc-folds-jumps-and-keeps-row-position ()
  (let ((reader
         (epub-reader-open (epub-reader-test-fixture "epub3-edge.epub")))
        toc)
    (unwind-protect
        (progn
          (with-current-buffer reader
            (setq toc (epub-reader-toc)))
          (with-current-buffer toc
            (should epub-reader-toc-mode)
            (should-not (plist-member textui-state :reader-buffer))
            (goto-char (epub-reader-toc--key-position "0"))
            (let ((key (get-text-property (point) 'epub-reader-toc-key)))
              (should (equal key "0"))
              (epub-reader-toc-toggle)
              (should (equal (get-text-property
                              (point) 'epub-reader-toc-key)
                             key))
              (should-not (string-match-p
                           "章一" (buffer-substring-no-properties
                                  (point-min) (point-max))))
              (epub-reader-toc-toggle))
            (let ((appendix
                   (epub-reader-toc--key-position "0/0/0")))
              (should appendix)
              (goto-char appendix)
              (epub-reader-toc-activate)))
          (with-current-buffer reader
            (should (equal (get-text-property
                            (point) 'epub-reader-anchor-id)
                           "appendix"))))
      (when (buffer-live-p reader) (kill-buffer reader))
      (should-not (buffer-live-p toc)))))

(ert-deftest epub-reader-ui-toc-marks-current-chapter-after-cross-spine-jump ()
  (epub-reader-ui-test--with-reader reader
    (let ((toc (epub-reader-toc)))
      (with-current-buffer toc
        (let ((second (epub-reader-toc--key-position "1")))
          (should second)
          (goto-char second)
          (epub-reader-toc-activate)
          (should (equal (get-text-property
                          (point) 'epub-reader-toc-key)
                         "1"))
          (should (eq (get-text-property (point) 'face)
                      'epub-reader-toc-current-face))))
      (with-current-buffer reader
        (should (= (plist-get textui-state :spine-index) 1))))))

(ert-deftest epub-reader-ui-toc-reopen-restores-selected-row ()
  (let ((reader
         (epub-reader-open (epub-reader-test-fixture "epub3-edge.epub")))
        toc)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer reader)
          (setq toc (epub-reader-toc))
          (let ((toc-window (get-buffer-window toc t)))
            (should (window-live-p toc-window))
            (select-window toc-window)
            (with-current-buffer toc
              (goto-char (epub-reader-toc--key-position "0/0/0"))
              (epub-reader-toc-quit))
            (should-not (get-buffer-window toc t)))
          (with-current-buffer reader
            (epub-reader-toc))
          (let ((toc-window (get-buffer-window toc t)))
            (should (window-live-p toc-window))
            (should
             (equal (with-current-buffer toc
                      (get-text-property (window-point toc-window)
                                         'epub-reader-toc-key))
                    "0/0/0"))))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest epub-reader-ui-completion-and-header-show-weighted-progress ()
  (epub-reader-ui-test--with-reader _buffer
    (let ((initial (epub-reader-ui--progress-percent))
          (header (epub-reader-ui--header-line)))
      (should (string-match-p "最小 EPUB 2" header))
      (should (string-match-p "哲学从问题开始" header))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _arguments) "第二章")))
        (epub-reader-jump))
      (should (= (plist-get textui-state :spine-index) 1))
      (should (> (epub-reader-ui--progress-percent) initial))
      (should (string-match-p "第二章 图像与论证"
                              (epub-reader-ui--header-line))))))

(ert-deftest epub-reader-ui-progress-uses-source-offset-and-reaches-endpoints ()
  (epub-reader-ui-test--with-reader _buffer
    (goto-char (epub-reader-ui--first-source-position))
    (should (= (epub-reader-ui--progress-percent) 0.0))
    (let* ((session epub-reader-ui--session)
           (block
            (cl-find-if
             (lambda (candidate)
               (> (length (epub-reader-block-text candidate)) 10))
             (append (epub-reader-ui--current-blocks session) nil)))
           (key (epub-reader-block-key block))
           (start (epub-reader-ui-test--block-position key))
           first last)
      (should start)
      (goto-char start)
      (setq first (epub-reader-ui--progress-percent))
      (goto-char (+ start (1- (length (epub-reader-block-text block)))))
      (setq last (epub-reader-ui--progress-percent))
      (should (> last first)))
    (epub-reader-next-chapter)
    (let ((blocks (epub-reader-ui--current-blocks)))
      (epub-reader-ui--goto-block-index (1- (length blocks)) t))
    (should (= (epub-reader-ui--progress-percent) 100.0))))

(ert-deftest epub-reader-ui-bookmark-list-jumps-deletes-and-persists ()
  (let ((directory (make-temp-file "epub-reader-bookmarks-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader list-buffer)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (goto-char (epub-reader-ui-test--source-position "id:mixed" 3))
            (epub-reader-add-bookmark "Mixed paragraph")
            (should (= (length (epub-reader-session-bookmarks
                                epub-reader-ui--session))
                       1)))
          (kill-buffer reader)
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (should (= (length (epub-reader-session-bookmarks
                                epub-reader-ui--session))
                       1))
            (setq list-buffer (epub-reader-bookmarks)))
          (with-current-buffer list-buffer
            (goto-char (point-min))
            (let ((position
                   (cl-loop for cursor from (point-min) below (point-max)
                            when (get-text-property
                                  cursor 'epub-reader-bookmark)
                            return cursor)))
              (should position)
              (goto-char position)
              (cl-letf (((symbol-function 'pop-to-buffer)
                         (lambda (&rest _arguments) reader)))
                (epub-reader-bookmark-list-activate))
              (with-current-buffer reader
                (let ((source-property
                       (get-text-property (point) 'epub-reader-source)))
                  (should (equal (aref source-property 1) "id:mixed"))
                  (should (= (aref source-property 2) 3))))
              (epub-reader-bookmark-list-delete)))
          (with-current-buffer reader
            (should-not (epub-reader-session-bookmarks
                         epub-reader-ui--session))))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-highlight-note-survives-reflow-and-reopen ()
  (let ((directory (make-temp-file "epub-reader-highlights-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader list-buffer)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (let* ((block (cl-find "mixed" (epub-reader-ui--current-blocks)
                                   :key #'epub-reader-block-element-id
                                   :test #'equal))
                   (text (substring-no-properties
                          (epub-reader-block-text block)))
                   (start-offset (string-match "Emacs" text))
                   (end-offset (+ (string-match "EPUB" text) 4))
                   (start (epub-reader-ui-test--source-position
                           "id:mixed" start-offset))
                   (end (1+ (epub-reader-ui-test--source-position
                             "id:mixed" (1- end-offset)))))
              (goto-char end)
              (set-mark start)
              (setq mark-active t transient-mark-mode t)
              (epub-reader-add-highlight start end)
              (goto-char (epub-reader-ui-test--source-position
                          "id:mixed" start-offset))
              (should (memq 'epub-reader-highlight-face
                            (ensure-list (get-text-property (point) 'face))))
              (let ((editor (epub-reader-edit-note)))
                (with-current-buffer editor
                  (erase-buffer)
                  (insert "中英混排笔记")
                  (epub-reader-note-save)))
              (cl-letf (((symbol-function 'textui--visible-width)
                         (lambda (_buffer) 42)))
                (textui-refresh reader)
                (epub-reader-ui--post-render reader))
              (goto-char (epub-reader-ui-test--source-position
                          "id:mixed" start-offset))
              (should (get-text-property (point)
                                         'epub-reader-annotation-ids))))
          (kill-buffer reader)
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (let ((annotation
                   (car (epub-reader-session-annotations
                         epub-reader-ui--session))))
              (should annotation)
              (should (equal (epub-reader-annotation-note annotation)
                             "中英混排笔记"))
              (should (equal
                       (epub-reader-locator-range-exact
                        (epub-reader-annotation-range annotation))
                       "Emacs阅读EPUB")))
            (setq list-buffer (epub-reader-annotations)))
          (with-current-buffer list-buffer
            (goto-char (point-min))
            (let ((position
                   (cl-loop for cursor from (point-min) below (point-max)
                            when (get-text-property
                                  cursor 'epub-reader-annotation)
                            return cursor)))
              (should position)
              (goto-char position)
              (should (string-match-p "中英混排笔记"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))
              (epub-reader-annotation-list-delete)))
          (with-current-buffer reader
            (should-not (epub-reader-session-annotations
                         epub-reader-ui--session))))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-english-cross-line-highlight-keeps-source-space ()
  (let ((directory (make-temp-file "epub-reader-english-range-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-reading-width 18)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (let* ((block
                    (cl-find "english" (epub-reader-ui--current-blocks)
                             :key #'epub-reader-block-element-id :test #'equal))
                   (key (epub-reader-block-key block))
                   (text (substring-no-properties
                          (epub-reader-block-text block)))
                   (lines (epub-reader-ui-test--source-lines key))
                   (pair
                    (cl-loop for left in lines for right in (cdr lines)
                             for left-last = (car (last left))
                             for right-first = (car right)
                             when (> right-first (1+ left-last))
                             return (cons left-last right-first)))
                   (from (max 0 (- (car pair) 3)))
                   (to (min (length text) (+ (cdr pair) 4)))
                   (start (epub-reader-ui-test--source-position key from))
                   (end (1+ (epub-reader-ui-test--source-position
                             key (1- to)))))
              (should pair)
              (goto-char end)
              (set-mark start)
              (setq mark-active t transient-mark-mode t)
              (let ((annotation (epub-reader-add-highlight start end)))
                (should
                 (equal
                  (epub-reader-locator-range-exact
                   (epub-reader-annotation-range annotation))
                  (substring text from to)))
                (should (string-match-p
                         " " (epub-reader-locator-range-exact
                              (epub-reader-annotation-range annotation))))
                (goto-char (epub-reader-ui-test--source-position key from))
                (should
                 (member (epub-reader-annotation-id annotation)
                         (get-text-property
                          (point) 'epub-reader-annotation-ids)))))))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-two-readers-merge-independent-highlights ()
  (let ((directory (make-temp-file "epub-reader-concurrent-highlights-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        first second reopened)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq first (epub-reader-open source)
                second (epub-reader-open source))
          (cl-labels
              ((add-range
                (buffer key from to)
                (with-current-buffer buffer
                  (let ((start (epub-reader-ui-test--source-position key from))
                        (end (1+ (epub-reader-ui-test--source-position
                                 key (1- to)))))
                    (goto-char end)
                    (set-mark start)
                    (setq mark-active t transient-mark-mode t)
                    (epub-reader-add-highlight start end)))))
            (add-range first "id:english" 0 5)
            (add-range second "id:mixed" 3 8))
          (kill-buffer second)
          (setq second nil)
          (kill-buffer first)
          (setq first nil)
          (setq reopened (epub-reader-open source))
          (with-current-buffer reopened
            (should (= (length (epub-reader-session-annotations
                                epub-reader-ui--session))
                       2))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (when (buffer-live-p reopened) (kill-buffer reopened))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-marks-only-sidecar-reopens-with-progress-enabled ()
  (let ((directory (make-temp-file "epub-reader-ui-marks-only-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory)
              (epub-reader-enable-progress nil))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (goto-char (epub-reader-ui-test--source-position "id:english" 0))
            (epub-reader-add-bookmark "English"))
          (kill-buffer reader)
          (setq reader nil)
          (let ((epub-reader-enable-progress t))
            (setq reader (epub-reader-open source)))
          (with-current-buffer reader
            (should (= (length (epub-reader-session-bookmarks
                                epub-reader-ui--session))
                       1))))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-live-mark-lists-refresh-when-reopened ()
  (let ((directory (make-temp-file "epub-reader-ui-live-lists-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader bookmark-list annotation-list)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (goto-char (epub-reader-ui-test--source-position "id:english" 0))
            (epub-reader-add-bookmark "First")
            (setq bookmark-list (epub-reader-bookmarks)))
          (with-current-buffer reader
            (goto-char (epub-reader-ui-test--source-position "id:mixed" 0))
            (epub-reader-add-bookmark "Second"))
          (with-current-buffer reader
            (cl-letf (((symbol-function 'display-buffer) #'identity))
              (epub-reader-bookmarks)))
          (with-current-buffer bookmark-list
            (should (= (epub-reader-ui-test--property-count
                        'epub-reader-bookmark)
                       2)))
          (cl-labels ((add-highlight
                       (key from to)
                       (let ((start (epub-reader-ui-test--source-position
                                     key from))
                             (end (1+ (epub-reader-ui-test--source-position
                                      key (1- to)))))
                         (goto-char end)
                         (set-mark start)
                         (setq mark-active t transient-mark-mode t)
                         (epub-reader-add-highlight start end))))
            (with-current-buffer reader
              (add-highlight "id:english" 0 5)
              (setq annotation-list (epub-reader-annotations)))
            (with-current-buffer reader
              (add-highlight "id:mixed" 3 8))
            (with-current-buffer reader
              (cl-letf (((symbol-function 'display-buffer) #'identity))
                (epub-reader-annotations))))
          (with-current-buffer annotation-list
            (should (= (epub-reader-ui-test--property-count
                        'epub-reader-annotation)
                       2))
            ;; Highlights are grouped under the chapter's own heading, not
            ;; under a hard-coded English "Chapter N" label.
            (let ((text (buffer-substring-no-properties
                         (point-min) (point-max))))
              (should (string-match-p "Language Layout" text))
              (should-not (string-match-p "Chapter 1" text)))))
      (when (buffer-live-p bookmark-list) (kill-buffer bookmark-list))
      (when (buffer-live-p annotation-list) (kill-buffer annotation-list))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-unvisited-degraded-annotation-is-visible-in-list ()
  (let ((directory (make-temp-file "epub-reader-ui-degraded-list-" t))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader list-buffer
        (resolve-count 0))
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open
                        (epub-reader-test-fixture "epub2.epub")))
          (with-current-buffer reader
            (let* ((session epub-reader-ui--session)
                   (chapter (epub-reader-ui--chapter-data session 1))
                   (block
                    (cl-find-if
                     (lambda (candidate)
                       (> (length (epub-reader-block-text candidate)) 6))
                     (append (epub-reader-chapter-data-blocks chapter) nil)))
                   (text (substring-no-properties
                          (epub-reader-block-text block)))
                   (exact (substring text 0 (min 6 (length text))))
                   (start (epub-reader-locator--create
                           :schema 3
                           :book-key (epub-reader-block-book-key block)
                           :spine-index 1
                           :path (epub-reader-block-document-path block)
                           :block "missing-block" :offset 0
                           :prefix "" :suffix (substring text (length exact)
                                                          (min (length text)
                                                               (+ (length exact)
                                                                  12)))
                           :context exact))
                   (end (copy-epub-reader-locator start))
                   (range (epub-reader-locator-range--create
                           :schema 1 :start start :end end :exact exact
                           :prefix "" :suffix
                           (epub-reader-locator-suffix start)))
                   (annotation
                    (epub-reader-annotation--create
                     :id "degraded-unvisited" :range range :note ""
                     :created 1.0)))
              (setf (epub-reader-locator-offset end) (1- (length exact)))
              (push annotation (epub-reader-session-annotations session))
              (epub-reader-annotation-index-put
               (epub-reader-session-annotation-index session) annotation)
              (cl-letf (((symbol-function 'epub-reader-locator-range-resolve)
                         (let ((original
                                (symbol-function
                                 'epub-reader-locator-range-resolve)))
                           (lambda (&rest arguments)
                             (cl-incf resolve-count)
                             (apply original arguments)))))
                (setq list-buffer (epub-reader-annotations)))
              ;; Opening the global list must not resolve an annotation from
              ;; an unvisited chapter.
              (should (= resolve-count 0))
              (should-not (epub-reader-annotation-quality annotation))))
          (with-current-buffer list-buffer
            (should-not (string-match-p "⚠" (buffer-string)))
            (goto-char
             (cl-loop for cursor from (point-min) below (point-max)
                      when (get-text-property cursor 'epub-reader-annotation)
                      return cursor))
            (cl-letf (((symbol-function 'pop-to-buffer) #'identity)
                      ((symbol-function 'epub-reader-locator-range-resolve)
                       (let ((original
                              (symbol-function
                               'epub-reader-locator-range-resolve)))
                         (lambda (&rest arguments)
                           (cl-incf resolve-count)
                           (apply original arguments)))))
              (epub-reader-annotation-list-activate))
            (should (= resolve-count 1))
            (should (string-match-p "⚠" (buffer-string)))))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t))))

(ert-deftest epub-reader-ui-open-takes-over-frame-and-quit-restores-layout ()
  (let ((epub-reader-open-full-frame t)
        buffer)
    (save-window-excursion
      (delete-other-windows)
      (split-window-right)
      (should (= (length (window-list nil 'no-minibuffer)) 2))
      (setq buffer (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (should (= (length (window-list nil 'no-minibuffer)) 1))
            (should (eq (window-buffer (selected-window)) buffer))
            (with-current-buffer buffer
              (epub-reader-quit))
            (should-not (buffer-live-p buffer))
            (should (= (length (window-list nil 'no-minibuffer)) 2)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest epub-reader-ui-open-keeps-layout-when-full-frame-is-disabled ()
  (let ((epub-reader-open-full-frame nil)
        buffer)
    (save-window-excursion
      (delete-other-windows)
      (split-window-right)
      (setq buffer (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (should (get-buffer-window buffer))
            (should (>= (length (window-list nil 'no-minibuffer)) 2))
            (with-current-buffer buffer
              (should-not epub-reader-ui--window-configuration)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest epub-reader-ui-opens-second-book-from-inside-a-reader ()
  (let ((epub-reader-enable-progress nil)
        first second)
    (unwind-protect
        (progn
          (setq first (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
          (with-current-buffer first
            (setq second
                  (epub-reader-open (epub-reader-test-fixture "epub3.epub"))))
          (should (buffer-live-p second))
          (with-current-buffer second
            (should (epub-reader-session-p epub-reader-ui--session))
            (should (> (buffer-size) 0))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun epub-reader-ui-test--mouse-event (buffer position)
  "Return a synthetic mouse-1 click on POSITION of BUFFER in a live window."
  (let ((window (or (get-buffer-window buffer t)
                    (progn (set-window-buffer (selected-window) buffer)
                           (selected-window)))))
    (list 'mouse-1
          (list window position '(0 . 0) 0 nil position '(0 . 0)
                nil '(0 . 0) '(1 . 1)))))

(ert-deftest epub-reader-ui-toc-mouse-click-visits-entry ()
  (let ((reader
         (epub-reader-open (epub-reader-test-fixture "epub3-edge.epub")))
        toc)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer reader)
          (setq toc (epub-reader-toc))
          (let ((position (with-current-buffer toc
                            (epub-reader-toc--key-position "0/0/0"))))
            (should position)
            (should (eq (lookup-key (get-text-property position 'keymap toc)
                                    [mouse-1])
                        #'epub-reader-toc-activate-mouse))
            (epub-reader-toc-activate-mouse
             (epub-reader-ui-test--mouse-event toc position)))
          (with-current-buffer reader
            (should (equal (get-text-property (point) 'epub-reader-anchor-id)
                           "appendix"))))
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest epub-reader-ui-bookmark-list-mouse-click-jumps ()
  (let ((directory (make-temp-file "epub-reader-bookmark-mouse-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader list-buffer)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (goto-char (epub-reader-ui-test--source-position "id:mixed" 3))
            (epub-reader-add-bookmark "Mixed paragraph")
            (goto-char (point-min))
            (setq list-buffer (epub-reader-bookmarks)))
          (let ((position
                 (with-current-buffer list-buffer
                   (cl-loop for cursor from (point-min) below (point-max)
                            when (get-text-property
                                  cursor 'epub-reader-bookmark)
                            return cursor))))
            (should position)
            (should (eq (lookup-key
                         (get-text-property position 'keymap list-buffer)
                         [mouse-1])
                        #'epub-reader-bookmark-list-activate-mouse))
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (&rest _arguments) reader)))
              (epub-reader-bookmark-list-activate-mouse
               (epub-reader-ui-test--mouse-event list-buffer position))))
          (with-current-buffer reader
            (should (equal (aref (get-text-property (point) 'epub-reader-source)
                                 1)
                           "id:mixed"))))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-file source)
      (delete-directory directory t))))

(ert-deftest epub-reader-ui-annotation-list-mouse-click-jumps ()
  (let ((directory (make-temp-file "epub-reader-annotation-mouse-" t))
        (source (make-temp-file "epub-reader-language-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        reader list-buffer)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (let* ((block (cl-find "mixed" (epub-reader-ui--current-blocks)
                                   :key #'epub-reader-block-element-id
                                   :test #'equal))
                   (text (substring-no-properties
                          (epub-reader-block-text block)))
                   (start-offset (string-match "Emacs" text))
                   (end-offset (+ (string-match "EPUB" text) 4))
                   (start (epub-reader-ui-test--source-position
                           "id:mixed" start-offset))
                   (end (1+ (epub-reader-ui-test--source-position
                             "id:mixed" (1- end-offset)))))
              (goto-char end)
              (set-mark start)
              (setq mark-active t transient-mark-mode t)
              (epub-reader-add-highlight start end)
              (deactivate-mark)
              (goto-char (point-min))
              (setq list-buffer (epub-reader-annotations))))
          (let ((position
                 (with-current-buffer list-buffer
                   (cl-loop for cursor from (point-min) below (point-max)
                            when (get-text-property
                                  cursor 'epub-reader-annotation)
                            return cursor))))
            (should position)
            (should (eq (lookup-key
                         (get-text-property position 'keymap list-buffer)
                         [mouse-1])
                        #'epub-reader-annotation-list-activate-mouse))
            (cl-letf (((symbol-function 'pop-to-buffer) #'identity))
              (epub-reader-annotation-list-activate-mouse
               (epub-reader-ui-test--mouse-event list-buffer position))))
          (with-current-buffer reader
            (should (get-text-property (point) 'epub-reader-annotation-ids))))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-file source)
      (delete-directory directory t))))

(ert-deftest epub-reader-ui-toc-wrapped-label-keeps-hanging-indent ()
  (let* ((entries
          (list (epub-reader-toc-entry--create
                 :label "第一回至第十回"
                 :children
                 (list (epub-reader-toc-entry--create
                        :label "第一回　甄士隱夢幻識通靈　賈雨村風塵懷閨秀"
                        :path "text/1.xhtml")
                       (epub-reader-toc-entry--create
                        :label "第二回　賈夫人仙逝揚州城　冷子興演說榮國府"
                        :path "text/2.xhtml")))))
         (buffer (generate-new-buffer " *epub-reader-toc-wrap-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (textui-mode)
          (setq-local textui--last-width 24
                      textui--render-function
                      (lambda (_width)
                        (list
                         (list :type :flex :direction :column :gap 0
                               :children
                               (mapcar #'epub-reader-toc--row-element
                                       (epub-reader-toc--rows
                                        entries nil "text/2.xhtml"))))))
          (textui-refresh buffer)
          (let* ((lines (split-string (buffer-substring-no-properties
                                       (point-min) (point-max))
                                      "\n"))
                 (second-start
                  (cl-position-if (lambda (line) (string-prefix-p "▶" line))
                                  lines))
                 (continuations (cl-subseq lines 2 second-start)))
            (should (string-prefix-p "  ▾ 第一回至第十回" (nth 0 lines)))
            (should (string-prefix-p "      第一回" (nth 1 lines)))
            ;; The long label wraps, and every continuation line is indented
            ;; to the label column instead of starting at the window edge.
            (should (>= (length continuations) 1))
            (dolist (line continuations)
              (should (string-match-p "\\`      [^ ]" line)))
            (should (string-prefix-p "▶     第二回" (nth second-start lines)))
            ;; Point on the blank indentation of a continuation line still
            ;; resolves to the wrapped row, and the row key lookup lands on
            ;; the row's first line.
            (goto-char (point-min))
            (forward-line 2)
            (should (equal (epub-reader-toc-row-key
                            (epub-reader-toc--row-at-point))
                           "0/0"))
            (goto-char (point-min))
            (forward-line second-start)
            (should (= (epub-reader-toc--key-position "0/1") (point)))))
      (kill-buffer buffer))))

(ert-deftest epub-reader-ui-numbered-chapter-label-follows-language ()
  (should (equal (epub-reader-ui--numbered-chapter-label "zh-CN" 2) "第二章"))
  (should (equal (epub-reader-ui--numbered-chapter-label "zh-Hant" 10)
                 "第十章"))
  (should (equal (epub-reader-ui--numbered-chapter-label "zh" 21)
                 "第二十一章"))
  (should (equal (epub-reader-ui--numbered-chapter-label "zh" 120)
                 "第120章"))
  (should (equal (epub-reader-ui--numbered-chapter-label "ja" 12) "第十二章"))
  (should (equal (epub-reader-ui--numbered-chapter-label "ko" 3) "제3장"))
  (should (equal (epub-reader-ui--numbered-chapter-label "en" 2) "Chapter 2"))
  (should (equal (epub-reader-ui--numbered-chapter-label nil 2) "Chapter 2")))

(ert-deftest epub-reader-ui-chapter-label-falls-back-to-toc-then-number ()
  (epub-reader-ui-test--with-reader reader
    (let* ((session (epub-reader-ui--current-session))
           (publication (epub-reader-session-publication session)))
      ;; The fixture chapter has a heading, which wins outright.
      (should (equal (epub-reader-ui--chapter-label session 0)
                     "第一章 哲学从问题开始"))
      ;; Without headings the table-of-contents label is used, and without a
      ;; TOC entry the number follows the publication language (zh-CN).
      (cl-letf (((symbol-function 'epub-reader-ui--heading-label)
                 (lambda (_blocks) nil)))
        (should (equal (epub-reader-ui--chapter-label session 0) "第一章"))
        (cl-letf (((symbol-function 'epub-reader-publication-toc)
                   (lambda (_publication) nil)))
          (should (equal (epub-reader-ui--chapter-label session 1)
                         "第二章"))
          (should (equal (epub-reader-ui--chapter-title) "第一章")))))))

(ert-deftest epub-reader-ui-custom-line-spacing-applies-to-prose ()
  (let ((epub-reader-line-spacing 0.4))
    (epub-reader-ui-test--with-reader _buffer
      (should (= line-spacing 0))
      (should (local-variable-p 'line-spacing))
      (let ((position
             (epub-reader-ui-test--block-position "path:body/1:p")))
        (should position)
        (let ((newline
               (save-excursion
                 (goto-char position)
                 (line-end-position))))
          (should (= (get-text-property newline 'line-spacing) 0.4)))))))

(ert-deftest epub-reader-ui-custom-paragraph-spacing-controls-blank-lines ()
  (dolist (spacing '(0 2))
    (let ((epub-reader-paragraph-spacing spacing))
      (epub-reader-ui-test--with-reader _buffer
        (let* ((first-key "path:body/1:p")
               (first (epub-reader-ui-test--block-position first-key))
               (second
                (epub-reader-ui-test--block-position
                 "path:body/2:blockquote/0:p")))
          (should first)
          (should second)
          (let ((first-last
                 (cl-loop for position from (point-min) below (point-max)
                          for source = (get-text-property
                                        position 'epub-reader-source)
                          when (and (epub-reader-locator-source-p source)
                                    (equal (aref source 1) first-key))
                          maximize position)))
            (should first-last)
            (should
             (= (- (line-number-at-pos second)
                   (line-number-at-pos first-last) 1)
                spacing))))))))

(ert-deftest epub-reader-ui-heading-face-inherits-prose-face ()
  (should (eq (face-attribute 'epub-reader-heading-1-face :inherit)
              'epub-reader-prose-face)))

(ert-deftest epub-reader-ui-default-text-scale-applies-before-rendering ()
  (let ((epub-reader-text-scale 1))
    (epub-reader-ui-test--with-reader _buffer
      (should (= text-scale-mode-amount 1))
      (should (epub-reader-ui-test--block-position "path:body/1:p"))
      (should (string-match-p
               "天地玄黄"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(provide 'epub-reader-ui-test)
;;; epub-reader-ui-test.el ends here
