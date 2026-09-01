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

(defun epub-reader-ui-test--visual-row (window)
  "Return WINDOW point's visual row relative to its start."
  (count-screen-lines (window-start window) (window-point window)
                      nil window))

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
                   '(continuation nil nil)))))

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
                    (before-row
                     (epub-reader-ui-test--visual-row (selected-window))))
                (should (= (plist-get textui-state :chunk-start) 0))
                (epub-reader-ui--maybe-shift-chunk)
                (redisplay t)
                (let ((after (epub-reader-ui--current-locator)))
                  (should (= (plist-get textui-state :chunk-start) 0))
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
            (goto-char (point-min))
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
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _arguments) "中英混排笔记")))
                (epub-reader-edit-note))
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
                                       (line-beginning-position)
                                       (line-end-position))))
              (epub-reader-annotation-list-delete)))
          (with-current-buffer reader
            (should-not (epub-reader-session-annotations
                         epub-reader-ui--session))))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
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

(provide 'epub-reader-ui-test)
;;; epub-reader-ui-test.el ends here
