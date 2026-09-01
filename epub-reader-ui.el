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
(require 'face-remap)
(require 'subr-x)
(require 'textui)
(require 'epub-reader-annotation)
(require 'epub-reader-locator)
(require 'epub-reader-publication)
(require 'epub-reader-render)
(require 'epub-reader-store)

(defcustom epub-reader-reading-width 76
  "Preferred width in character cells of the centered reading column."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-open-full-frame t
  "Non-nil means an opened book takes over the whole frame.
`epub-reader-open' then shows the reader in the selected window and hides
every other window, and `epub-reader-quit' restores the window layout that
was in place before the book was opened.  When nil, the reader buffer is only
displayed through `display-buffer' and the existing windows stay as they are."
  :type 'boolean
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

(defcustom epub-reader-first-paint-max-blocks 2
  "Maximum semantic blocks rendered synchronously on chapter entry."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-first-paint-max-characters 4000
  "Maximum source characters rendered synchronously on chapter entry."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-scroll-chunk-max-blocks 1
  "Maximum new semantic blocks rendered in a cold interactive chunk shift."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-scroll-chunk-max-characters 3000
  "Maximum source characters rendered in a cold interactive chunk shift."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-background-idle-delay 0.15
  "Idle seconds between reader background jobs."
  :type 'number
  :group 'epub-reader)

(defcustom epub-reader-enable-progress t
  "Whether reader buffers restore and persist versioned progress sidecars."
  :type 'boolean
  :group 'epub-reader)

(defcustom epub-reader-save-idle-delay 2.0
  "Idle seconds before the current semantic position is flushed."
  :type 'number
  :group 'epub-reader)

(defface epub-reader-header-face
  '((t (:inherit shadow :weight semibold)))
  "Face for the publication and chapter header."
  :group 'epub-reader)

(defface epub-reader-footer-face
  '((t (:inherit shadow :height 0.9)))
  "Face for the reader key-hint footer."
  :group 'epub-reader)

(defface epub-reader-toc-current-face
  '((t (:inherit highlight :weight bold)))
  "Face for the current spine entry in the TOC buffer."
  :group 'epub-reader)

(defface epub-reader-toc-group-face
  '((t (:inherit font-lock-keyword-face :weight semibold)))
  "Face for collapsible TOC groups."
  :group 'epub-reader)

(cl-defstruct (epub-reader-session
               (:constructor epub-reader-session--create))
  "Non-UI state owned by one reader buffer."
  publication current-chapter dom-cache store
  refreshing-p producer-block-count history-back history-forward toc-buffer
  bookmark-buffer annotation-buffer bookmarks annotations
  spine-weights total-weight
  progress-key progress-dirty-p progress-timer progress-callback
  background-generation background-jobs background-timer background-callback)

(cl-defstruct (epub-reader-chapter-data
               (:constructor epub-reader-chapter-data--create))
  "Cached parsed and normalized data for one spine document."
  section blocks block-index anchor-index character-count character-prefixes
  locator-index)

(cl-defstruct (epub-reader-viewport
               (:constructor epub-reader-viewport--create))
  "One window's semantic point and top-of-window positions."
  window point-locator top-locator visual-row)

(cl-defstruct (epub-reader-view-state
               (:constructor epub-reader-view-state--create))
  "Semantic point plus all live window viewport records."
  point-locator viewports)

(cl-defstruct (epub-reader-toc-row
               (:constructor epub-reader-toc-row--create))
  "One flattened visible TOC row."
  key entry depth expanded-p current-p)

(defvar-local epub-reader-ui--window-configuration nil
  "Window configuration to restore when this reader buffer is quit.
Set only when the book took over the frame on opening.")

(defvar-local epub-reader-ui--session nil
  "Domain session owned by the current EPUB reader buffer.")

(defvar-local epub-reader-ui--saved-line-spacing nil
  "Saved `(LOCAL-P . VALUE)' for restoring the user's line spacing.")

(defvar-local epub-reader-ui--prose-line-spacing nil
  "Line spacing copied onto non-image rows in the current reader buffer.")

(defvar-local epub-reader-toc--reader-buffer nil
  "Reader buffer controlled by the current TOC TextUI buffer.")

(defvar-local epub-reader-bookmark-list--reader-buffer nil
  "Reader buffer controlled by the current bookmark list.")

(defvar-local epub-reader-annotation-list--reader-buffer nil
  "Reader buffer controlled by the current annotation list.")

(defvar-keymap epub-reader-ui-mode-map
  :doc "Keymap active in EPUB reader TextUI buffers."
  "n" #'epub-reader-next-chapter
  "]" #'epub-reader-next-chapter
  "p" #'epub-reader-previous-chapter
  "[" #'epub-reader-previous-chapter
  "SPC" #'epub-reader-scroll-forward
  "S-SPC" #'epub-reader-scroll-backward
  "b" #'epub-reader-history-back
  "f" #'epub-reader-history-forward
  "t" #'epub-reader-toc
  "g" #'epub-reader-jump
  "m" #'epub-reader-add-bookmark
  "M" #'epub-reader-bookmarks
  "h" #'epub-reader-add-highlight
  "e" #'epub-reader-edit-note
  "a" #'epub-reader-annotations
  "RET" #'epub-reader-follow-link
  "q" #'epub-reader-quit)

(defvar-keymap epub-reader-toc-mode-map
  :doc "Keymap active in EPUB TOC TextUI buffers."
  "RET" #'epub-reader-toc-activate
  "TAB" #'epub-reader-toc-toggle
  "q" #'epub-reader-toc-quit)

(defvar-keymap epub-reader-bookmark-list-mode-map
  :doc "Keymap active in EPUB bookmark list buffers."
  "RET" #'epub-reader-bookmark-list-activate
  "d" #'epub-reader-bookmark-list-delete
  "q" #'epub-reader-bookmark-list-quit)

(defvar-keymap epub-reader-annotation-list-mode-map
  :doc "Keymap active in EPUB annotation list buffers."
  "RET" #'epub-reader-annotation-list-activate
  "d" #'epub-reader-annotation-list-delete
  "e" #'epub-reader-annotation-list-edit-note
  "q" #'epub-reader-annotation-list-quit)

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
        ;; A newline property can enlarge buffer spacing, but it cannot shrink
        ;; spacing already accumulated by visible glyphs.  Use a zero baseline
        ;; and put the user's value back on every non-image newline so tiled
        ;; image slices alone remain contiguous.
        (setq-local epub-reader-ui--saved-line-spacing
                    (cons (local-variable-p 'line-spacing) line-spacing))
        (setq-local epub-reader-ui--prose-line-spacing
                    (or line-spacing
                        (frame-parameter (selected-frame) 'line-spacing)))
        (setq-local line-spacing 0)
        (epub-reader-ui--disable-image-line-spacing (current-buffer))
        ;; TextUI already emits physical lines at the requested frame width.
        ;; A second Emacs soft-wrap can expose a lone glyph in the margin.
        (setq-local truncate-lines t)
        ;; Fixed-width TextUI rows need neither Emacs continuation nor
        ;; truncation fringe glyphs; those form a distracting vertical rail
        ;; beside centered CJK prose.
        (setq-local fringe-indicator-alist
                    (copy-tree fringe-indicator-alist))
        (setcdr (assq 'truncation fringe-indicator-alist) '(nil nil))
        (setcdr (assq 'continuation fringe-indicator-alist) '(nil nil))
        (add-hook 'post-command-hook
                  #'epub-reader-ui--maybe-shift-chunk nil t)
        (add-hook 'post-command-hook
                  #'epub-reader-ui--progress-post-command t t)
        (add-hook 'text-scale-mode-hook
                  #'epub-reader-ui--refresh-for-text-scale nil t))
    (remove-hook 'post-command-hook
                 #'epub-reader-ui--maybe-shift-chunk t)
    (remove-hook 'post-command-hook
                 #'epub-reader-ui--progress-post-command t)
    (remove-hook 'text-scale-mode-hook
                 #'epub-reader-ui--refresh-for-text-scale t)
    (when (consp epub-reader-ui--saved-line-spacing)
      (if (car epub-reader-ui--saved-line-spacing)
          (setq-local line-spacing
                      (cdr epub-reader-ui--saved-line-spacing))
        (kill-local-variable 'line-spacing)))
    (setq-local epub-reader-ui--saved-line-spacing nil
                epub-reader-ui--prose-line-spacing nil)))

(define-minor-mode epub-reader-toc-mode
  "Minor mode for the secondary EPUB table-of-contents buffer."
  :init-value nil
  :lighter " EPUB-TOC"
  :keymap epub-reader-toc-mode-map
  (setq-local truncate-lines t))

(define-minor-mode epub-reader-bookmark-list-mode
  "Minor mode for the secondary EPUB bookmark list buffer."
  :init-value nil
  :lighter " EPUB-Bookmarks"
  :keymap epub-reader-bookmark-list-mode-map
  (setq-local truncate-lines t))

(define-minor-mode epub-reader-annotation-list-mode
  "Minor mode for the secondary EPUB annotation list buffer."
  :init-value nil
  :lighter " EPUB-Annotations"
  :keymap epub-reader-annotation-list-mode-map
  (setq-local truncate-lines t))

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

(defun epub-reader-ui--decode-values (values decoder kind)
  "Decode plain VALUES with DECODER, warning and skipping invalid KIND values."
  (let (decoded)
    (dolist (value values (nreverse decoded))
      (condition-case error-data
          (push (funcall decoder value) decoded)
        (error
         (display-warning
          'epub-reader
          (format "Invalid saved EPUB %s ignored: %s"
                  kind (error-message-string error-data))
          :warning))))))

(defun epub-reader-ui--flush-reader-marks (session)
  "Durably flush pending bookmarks or annotations for SESSION."
  (condition-case error-data
      (epub-reader-store-flush (epub-reader-session-store session))
    (error
     (user-error "Could not save EPUB bookmark or annotation: %s"
                 (error-message-string error-data)))))

(defun epub-reader-ui--current-chapter (&optional session)
  "Return SESSION's current canonical chapter data."
  (or (epub-reader-session-current-chapter
       (or session (epub-reader-ui--current-session)))
      (user-error "EPUB chapter data is unavailable")))

(defun epub-reader-ui--current-section (&optional session)
  "Return SESSION's current publication section."
  (epub-reader-chapter-data-section
   (epub-reader-ui--current-chapter session)))

(defun epub-reader-ui--current-blocks (&optional session)
  "Return SESSION's current canonical block vector."
  (epub-reader-chapter-data-blocks
   (epub-reader-ui--current-chapter session)))

(defun epub-reader-ui--current-block-index (&optional session)
  "Return SESSION's current block-key index."
  (epub-reader-chapter-data-block-index
   (epub-reader-ui--current-chapter session)))

(defun epub-reader-ui--current-anchor-index (&optional session)
  "Return SESSION's current fragment index."
  (epub-reader-chapter-data-anchor-index
   (epub-reader-ui--current-chapter session)))

(defun epub-reader-ui--current-character-prefixes (&optional session)
  "Return cumulative source-character counts for SESSION's chapter."
  (epub-reader-chapter-data-character-prefixes
   (epub-reader-ui--current-chapter session)))

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
  "Return indices, total characters, and character prefixes for BLOCKS."
  (let ((block-index (make-hash-table :test #'equal))
        (anchor-index (make-hash-table :test #'equal))
        (prefixes (make-vector (1+ (length blocks)) 0))
        (characters 0))
    (cl-loop for block across blocks
             for index from 0
             do (puthash (epub-reader-block-key block) index block-index)
             when (epub-reader-block-element-id block)
             do (puthash (epub-reader-block-element-id block)
                         index anchor-index)
             do (setq characters
                      (+ characters (length (epub-reader-block-text block))))
             do (aset prefixes (1+ index) characters))
    (list block-index anchor-index characters prefixes)))

(defun epub-reader-ui--chapter-data (session index)
  "Return cached chapter data for SESSION spine INDEX, loading if needed."
  (let* ((publication (epub-reader-session-publication session))
         (key (epub-reader-ui--chapter-cache-key publication index))
         (cache (epub-reader-session-dom-cache session))
         (chapter (gethash key cache)))
    (unless chapter
      (let* ((section
              (epub-reader-publication-load-section publication index))
             (blocks
              (vconcat (epub-reader-render-section publication section)))
             (indices (epub-reader-ui--index-blocks blocks))
             (locator-index
              (epub-reader-locator-build-chapter-index
               (epub-reader-ui--locator-records blocks))))
        (setq chapter
              (epub-reader-chapter-data--create
               :section section :blocks blocks
               :block-index (nth 0 indices) :anchor-index (nth 1 indices)
               :character-count (nth 2 indices)
               :character-prefixes (nth 3 indices)
               :locator-index locator-index))
        (puthash key chapter cache)))
    chapter))

(defun epub-reader-ui--load-chapter (session index)
  "Activate spine INDEX in SESSION, reusing its normalized chapter cache."
  (let ((chapter (epub-reader-ui--chapter-data session index)))
    (setf (epub-reader-session-current-chapter session) chapter)
    chapter))

(defun epub-reader-ui--prefetch-chapter (session index)
  "Load SESSION spine INDEX without changing the active chapter."
  (epub-reader-ui--chapter-data session index))

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

(defun epub-reader-ui--chunk-end
    (blocks start &optional max-blocks max-characters)
  "Return exclusive chunk end in BLOCKS from START under both budgets."
  (let ((end start)
        (characters 0)
        (block-limit (or max-blocks epub-reader-chunk-max-blocks))
        (character-limit
         (or max-characters epub-reader-chunk-max-characters))
        (length (length blocks)))
    (while (and (< end length)
                (< (- end start) block-limit)
                (or (= end start)
                    (<= (+ characters
                           (length (epub-reader-block-text (aref blocks end))))
                        character-limit)))
      (setq characters
            (+ characters
               (length (epub-reader-block-text (aref blocks end))))
            end (1+ end)))
    end))

(defun epub-reader-ui--chunk-range (blocks target-index &optional small-budget)
  "Return a budgeted range containing TARGET-INDEX.
SMALL-BUDGET may be `first' for chapter entry or `scroll' for a cold shift."
  (let* ((length (length blocks))
         (target (max 0 (min target-index (max 0 (1- length)))))
         (max-blocks
          (pcase small-budget
            ('scroll epub-reader-scroll-chunk-max-blocks)
            ((pred identity) epub-reader-first-paint-max-blocks)))
         (max-characters
          (pcase small-budget
            ('scroll epub-reader-scroll-chunk-max-characters)
            ((pred identity) epub-reader-first-paint-max-characters)))
         (start
          (max 0
               (- target
                  (if small-budget
                      (/ (max 1 max-blocks) 2)
                    (epub-reader-ui--overscan-blocks)))))
         (end (epub-reader-ui--chunk-end
               blocks start max-blocks max-characters)))
    (when (>= target end)
      (setq start target
            end (epub-reader-ui--chunk-end
                 blocks start max-blocks max-characters)))
    (list start end)))

(defun epub-reader-ui--state-with-chunk (state start end)
  "Return copied STATE with chapter chunk START and END."
  (let ((next (copy-sequence state)))
    (setq next (plist-put next :chunk-start start))
    (plist-put next :chunk-end end)))

(defun epub-reader-ui--cancel-background-work (session)
  "Cancel pending lifecycle-bound background work for SESSION."
  (when (timerp (epub-reader-session-background-timer session))
    (cancel-timer (epub-reader-session-background-timer session)))
  (setf (epub-reader-session-background-timer session) nil
        (epub-reader-session-background-jobs session) nil))

(defun epub-reader-ui--arm-background-work (session generation)
  "Arm SESSION's next idle job for GENERATION."
  (let ((callback (epub-reader-session-background-callback session)))
    (when (and callback
               (epub-reader-session-background-jobs session)
               (= generation
                  (or (epub-reader-session-background-generation session) 0)))
      (setf (epub-reader-session-background-timer session)
            (run-with-idle-timer
             epub-reader-background-idle-delay nil callback generation)))))

(defun epub-reader-ui--queue-image-job (session index start end)
  "Queue an idle image job for SESSION chapter INDEX and block range.
An already queued dynamic image job for the chapter covers whatever chunk is
current when it runs, so it also covers this request."
  (unless (cl-some
           (lambda (job)
             (and (eq (car job) 'images)
                  (= (cadr job) index)
                  (or (null (nth 2 job))
                      (equal job (list 'images index start end)))))
           (epub-reader-session-background-jobs session))
    (setf (epub-reader-session-background-jobs session)
          (append (epub-reader-session-background-jobs session)
                  (list (list 'images index start end)))))
  (unless (timerp (epub-reader-session-background-timer session))
    (epub-reader-ui--arm-background-work
     session (or (epub-reader-session-background-generation session) 0))))

(defun epub-reader-ui--background-image-job
    (session index start end)
  "Materialize SESSION images in INDEX block range START to END."
  (when (= index (epub-reader-ui--state-value :spine-index))
    (let* ((start (or start (plist-get textui-state :chunk-start)))
           (end (or end (plist-get textui-state :chunk-end)))
           (chapter (epub-reader-session-current-chapter session))
           (blocks (epub-reader-chapter-data-blocks chapter))
           (publication (epub-reader-session-publication session))
           (section (epub-reader-chapter-data-section chapter))
           changed)
      (cl-loop for block-index from start below (min end (length blocks))
               for block = (aref blocks block-index)
               when (and (eq (epub-reader-block-kind block) 'image)
                         (epub-reader-block-image-href block)
                         (not (epub-reader-block-image-file block))
                         (not (epub-reader-block-image-error block)))
               do (condition-case error-data
                      (progn
                        (epub-reader-render-materialize-image
                         block publication section)
                        (setq changed t))
                    (epub-reader-publication-resource-busy
                     ;; A competing reader owns extraction.  Keep the block
                     ;; retryable and let the next scheduled chapter visit try.
                     (message "%s" (error-message-string error-data)))))
      (when changed
        (textui-refresh-region
         (current-buffer) 'chapter #'epub-reader-ui--chapter-elements)
        (epub-reader-ui--post-render (current-buffer))))))

(defun epub-reader-ui--background-expand-job (session index)
  "Expand SESSION's first-paint chunk for spine INDEX to its full budget."
  (when (= index (epub-reader-ui--state-value :spine-index))
    (let* ((blocks (epub-reader-ui--current-blocks session))
           (locator (epub-reader-locator-at-point index))
           (target
            (or (and locator
                     (gethash (epub-reader-locator-block locator)
                              (epub-reader-ui--current-block-index session)))
                (plist-get textui-state :chunk-start)
                0))
           (range (epub-reader-ui--chunk-range blocks target)))
      (unless (and (= (car range) (plist-get textui-state :chunk-start))
                   (= (cadr range) (plist-get textui-state :chunk-end)))
        (epub-reader-ui--refresh-chunk (car range) (cadr range))))))

(defun epub-reader-ui--run-background-job (session generation)
  "Run one SESSION idle job for GENERATION, then arm the next one."
  (setf (epub-reader-session-background-timer session) nil)
  (when (= generation
           (or (epub-reader-session-background-generation session) 0))
    (let ((job (pop (epub-reader-session-background-jobs session))))
      (when job
        (condition-case error-data
            (pcase (car job)
              ('prefetch
               (epub-reader-ui--prefetch-chapter session (cadr job)))
              ('images
               (epub-reader-ui--background-image-job
                session (nth 1 job) (nth 2 job) (nth 3 job)))
              ('expand
               (epub-reader-ui--background-expand-job session (cadr job))))
          (error
           (message "EPUB background job failed: %s"
                    (error-message-string error-data))))))
    (epub-reader-ui--arm-background-work session generation)))

(defun epub-reader-ui--schedule-background-work (session index)
  "Schedule prefetch, image loading, and chunk expansion for SESSION INDEX."
  (epub-reader-ui--cancel-background-work session)
  (let* ((generation
          (1+ (or (epub-reader-session-background-generation session) 0)))
         (publication (epub-reader-session-publication session))
         (count (length (epub-reader-publication-spine publication)))
         jobs)
    ;; The next chapter is more valuable than current images: the reading
    ;; budget explicitly permits images to arrive after readable text.
    (when (< (1+ index) count)
      (push (list 'prefetch (1+ index)) jobs))
    (push (list 'expand index) jobs)
    (push (list 'images index nil nil) jobs)
    (setf (epub-reader-session-background-generation session) generation
          (epub-reader-session-background-jobs session) (nreverse jobs))
    (epub-reader-ui--arm-background-work session generation)))

(defun epub-reader-ui--spine-weights (publication)
  "Return central-directory size weights for PUBLICATION's reading spine."
  (vconcat
   (cl-loop for item across (epub-reader-publication-spine publication)
            for resource = (epub-reader-spine-item-resource item)
            collect (max 1 (or (epub-reader-resource-size resource) 1)))))

(defun epub-reader-ui--current-locator ()
  "Return the current semantic locator, or nil outside chapter content."
  (epub-reader-locator-at-point
   (epub-reader-ui--state-value :spine-index)))

(defun epub-reader-ui--record-history ()
  "Push the current semantic position onto back history."
  (let* ((session (epub-reader-ui--current-session))
         (locator (epub-reader-ui--current-locator)))
    (when locator
      (setf (epub-reader-session-history-back session)
            (cons locator (epub-reader-session-history-back session))
            (epub-reader-session-history-forward session) nil))))

(defun epub-reader-ui--chapter-title ()
  "Return a readable title for the current chapter."
  (let ((blocks
         (epub-reader-ui--current-blocks)))
    (or (cl-loop for block across blocks
                 when (eq (epub-reader-block-kind block) 'heading)
                 return (string-trim
                         (substring-no-properties
                          (epub-reader-block-text block))))
        (format "Chapter %d" (1+ (epub-reader-ui--state-value :spine-index))))))

(defun epub-reader-ui--progress-percent ()
  "Return weighted whole-book progress for point in the current buffer."
  (let* ((session (epub-reader-ui--current-session))
         (weights (epub-reader-session-spine-weights session))
         (total (max 1 (or (epub-reader-session-total-weight session) 1)))
         (spine-index (epub-reader-ui--state-value :spine-index))
         (blocks (epub-reader-ui--current-blocks session))
         (chapter (epub-reader-ui--current-chapter session))
         (locator (epub-reader-ui--current-locator))
         (block-index
          (or (and locator
                   (gethash (epub-reader-locator-block locator)
                            (epub-reader-ui--current-block-index session)))
              0))
         (block (and (> (length blocks) 0) (aref blocks block-index)))
         (block-length (if block (length (epub-reader-block-text block)) 0))
         (character-count
          (epub-reader-chapter-data-character-count chapter))
         (prefixes (epub-reader-ui--current-character-prefixes session))
         (source-offset
          (if locator
              (min (epub-reader-locator-offset locator)
                   (max 0 (1- block-length)))
            0))
         (character-position
          (+ (if (< block-index (length prefixes))
                 (aref prefixes block-index)
               0)
             source-offset))
         (local
          (cond
           ((> character-count 1)
            (/ (float character-position) (1- character-count)))
           ((and locator
                 (= spine-index (1- (length weights))))
            1.0)
           (t 0.0)))
         (before (cl-loop for index below spine-index
                          sum (aref weights index)))
         (current (aref weights spine-index)))
    (min 100.0
         (max 0.0 (* 100.0 (/ (+ before (* current local)) total))))))

(defun epub-reader-ui--header-line ()
  "Return book, chapter, and weighted progression for `header-line-format'."
  (let* ((session (epub-reader-ui--current-session))
         (publication (epub-reader-session-publication session)))
    (format " %s  ·  %s  ·  %.1f%% "
            (epub-reader-publication-title publication)
            (epub-reader-ui--chapter-title)
            (epub-reader-ui--progress-percent))))

(defun epub-reader-ui--cancel-progress-timer (session)
  "Cancel SESSION's one-shot progress timer, if any."
  (let ((timer (epub-reader-session-progress-timer session)))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (epub-reader-session-progress-timer session) nil)))

(defun epub-reader-ui--schedule-progress-save (session)
  "Debounce one idle progress flush for dirty SESSION."
  (when (and (epub-reader-session-store session)
             (epub-reader-session-progress-dirty-p session))
    (epub-reader-ui--cancel-progress-timer session)
    (let ((callback (epub-reader-session-progress-callback session)))
      (unless callback
        (error "EPUB progress effect is unavailable"))
      (setf (epub-reader-session-progress-timer session)
            (run-with-idle-timer
             epub-reader-save-idle-delay nil callback)))))

(defun epub-reader-ui--current-progress-key ()
  "Return a stable plain-data key for the current semantic position."
  (let ((locator (epub-reader-ui--current-locator)))
    (and locator (epub-reader-locator-to-plist locator))))

(defun epub-reader-ui--observe-progress (&optional dirty)
  "Notice a changed semantic position and optionally mark it DIRTY."
  (let* ((session (epub-reader-ui--current-session))
         (store (epub-reader-session-store session))
         (locator (and epub-reader-enable-progress store
                       (epub-reader-ui--current-locator)))
         (key (and locator (epub-reader-locator-to-plist locator))))
    (when (and key
               (not (equal key (epub-reader-session-progress-key session))))
      (when dirty
        ;; Stage is an in-memory capture, so its timestamp represents the
        ;; actual locator change.  Idle/chapter/kill paths only flush this
        ;; snapshot and cannot turn a late close into a newer movement.
        (epub-reader-store-stage store locator)
        (setf (epub-reader-session-progress-dirty-p session) t)
        (epub-reader-ui--schedule-progress-save session))
      (setf (epub-reader-session-progress-key session) key))
    key))

(defun epub-reader-ui--initialize-progress-position ()
  "Record the displayed position as a clean progress baseline."
  (let ((session (epub-reader-ui--current-session)))
    (epub-reader-ui--cancel-progress-timer session)
    (setf (epub-reader-session-progress-key session)
          (and epub-reader-enable-progress
               (epub-reader-session-store session)
               (epub-reader-ui--current-progress-key))
          (epub-reader-session-progress-dirty-p session) nil)))

(defun epub-reader-ui--progress-post-command ()
  "Mark progress dirty after a command changes the semantic locator."
  (when (and (epub-reader-session-p epub-reader-ui--session)
             (not (epub-reader-session-refreshing-p
                   epub-reader-ui--session)))
    (epub-reader-ui--observe-progress t)))

(defun epub-reader-ui--save-progress (&optional flush)
  "Flush the last observed progress snapshot when FLUSH is non-nil."
  (let* ((session (epub-reader-ui--current-session))
         (store (epub-reader-session-store session)))
    (when store
      (when (epub-reader-session-progress-dirty-p session)
        (epub-reader-ui--cancel-progress-timer session))
      ;; A previous flush may have failed after staging.  Retrying an explicit
      ;; flush must not depend on observing another point movement.
      (when flush
        (epub-reader-store-flush store)
        (setf (epub-reader-session-progress-dirty-p session) nil)))
    (and store (epub-reader-store-pending store))))

(defun epub-reader-ui--save-progress-safely (&optional flush)
  "Save progress like `epub-reader-ui--save-progress' without blocking reading."
  (condition-case error-data
      (epub-reader-ui--save-progress flush)
    (error
     (message "EPUB progress save failed: %s"
              (error-message-string error-data))
     nil)))

(defun epub-reader-ui--restore-target-index (session locator)
  "Return SESSION block index most likely to resolve LOCATOR."
  (or (gethash (epub-reader-locator-block locator)
               (epub-reader-ui--current-block-index session))
      (let ((quote (concat (or (epub-reader-locator-prefix locator) "")
                           (or (epub-reader-locator-suffix locator) ""))))
        (and (not (string-empty-p quote))
             (cl-loop for block across (epub-reader-ui--current-blocks session)
                      for index from 0
                      when (string-match-p
                            (regexp-quote quote)
                            (epub-reader-block-text block))
                      return index)))
      0))

(defun epub-reader-ui--restore-progress ()
  "Resolve pending saved progress and report exact or degraded quality."
  (let ((locator (plist-get textui-state :pending-locator)))
    (when locator
      (let* ((target
              (epub-reader-ui--restore-target-index
               (epub-reader-ui--current-session) locator))
             (_visible (epub-reader-ui--ensure-block-visible target))
             (resolution (epub-reader-locator-goto locator))
             (quality (epub-reader-locator-resolution-quality resolution)))
        (setq textui-state
              (plist-put
               (plist-put (copy-sequence textui-state)
                          :pending-locator nil)
               :restore-quality quality))
        (cond
         ((eq quality 'exact)
          (message "EPUB progress restored exactly"))
         ((epub-reader-locator-resolution-position resolution)
          (message "EPUB progress restored with degraded match: %s" quality))
         (t
          (display-warning
           'epub-reader
           (format "Saved EPUB progress could not be restored: %s" quality)
           :warning)))
        resolution))))

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
  "Return the reader key hint."
  (list :type :text
        :value
        (propertize
         (concat "SPC page  ·  n/p chapter  ·  m bookmark  ·  h highlight"
                 "  ·  t TOC  ·  a highlights")
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

(defun epub-reader-ui--image-row-budget ()
  "Return image rows adjusted for this buffer's remapped font height.
TextUI's public image contract leaves row allocation to its caller.  Use the
smallest budget required by any live view of this buffer so a text-scale face
remap does not leave image slices measured in unscaled frame rows."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if (null windows)
        epub-reader-image-rows
      (max
       1
       (apply
        #'min
        (mapcar
         (lambda (window)
           (let* ((frame (window-frame window))
                  (base-height (max 1 (frame-char-height frame)))
                  (font-height (max 1 (window-font-height window))))
             (ceiling (/ (float (* epub-reader-image-rows base-height))
                         font-height))))
         windows))))))

(defun epub-reader-ui--locator-records (blocks)
  "Return canonical locator records for semantic BLOCKS."
  (cl-loop for block across blocks
           collect
           (list (epub-reader-block-book-key block)
                 (epub-reader-block-spine-index block)
                 (epub-reader-block-document-path block)
                 (epub-reader-block-key block)
                 (substring-no-properties (epub-reader-block-text block)))))

(defun epub-reader-ui--annotation-spans-by-block (session chapter)
  "Resolve SESSION annotations against CHAPTER and index their source spans."
  (let ((blocks (epub-reader-chapter-data-blocks chapter))
        (locator-index (epub-reader-chapter-data-locator-index chapter))
        (table (make-hash-table :test #'equal)))
    (dolist (annotation (epub-reader-session-annotations session))
      (let* ((range (epub-reader-annotation-range annotation))
             (start (epub-reader-locator-range-start range))
             (section-path
              (and (> (length blocks) 0)
                   (epub-reader-block-document-path (aref blocks 0)))))
        (when (equal (epub-reader-locator-path start) section-path)
          (let* ((resolution
                  (epub-reader-locator-range-resolve range locator-index))
                 (quality
                  (epub-reader-locator-range-resolution-quality resolution)))
            (setf (epub-reader-annotation-quality annotation) quality)
            (dolist (span
                     (epub-reader-locator-range-resolution-spans resolution))
              (let ((value
                     (list :start (nth 1 span) :end (nth 2 span)
                           :id (epub-reader-annotation-id annotation)
                           :quality quality
                           :note (epub-reader-annotation-note annotation))))
                (puthash (car span)
                         (cons value (gethash (car span) table)) table)))))))
    table))

(defun epub-reader-ui--chapter-elements (available-width)
  "Return the current budgeted chapter region at AVAILABLE-WIDTH."
  (let* ((session (epub-reader-ui--current-session))
         (chapter (epub-reader-ui--current-chapter session))
         (blocks (epub-reader-chapter-data-blocks chapter))
         (start (or (plist-get textui-state :chunk-start) 0))
         (end (or (plist-get textui-state :chunk-end) (length blocks)))
         (image-rows (epub-reader-ui--image-row-budget))
         (highlights (epub-reader-ui--annotation-spans-by-block
                      session chapter))
         elements)
    (cl-loop for index from start below (min end (length blocks))
             do (push (epub-reader-render-block-element
                       (aref blocks index)
                       (epub-reader-session-publication session)
                       (epub-reader-chapter-data-section
                        (epub-reader-ui--current-chapter session))
                       image-rows t
                       (gethash (epub-reader-block-key (aref blocks index))
                                highlights))
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
    (epub-reader-ui--disable-image-line-spacing (current-buffer))
    (epub-reader-ui--attach-link-actions (current-buffer))
    (epub-reader-ui--mark-chrome-regions (current-buffer)))
  nil)

(defun epub-reader-ui--disable-image-line-spacing (&optional buffer)
  "Keep user line spacing on prose but exclude it from image rows in BUFFER.
TextUI image leaves divide an image into fixed-height character rows.  Positive
buffer or inherited line spacing would otherwise introduce visible seams and
can make the final slices appear to overlap following content."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (let ((inhibit-read-only t))
        (while (< (point) (point-max))
          (let* ((start (line-beginning-position))
                 (newline (line-end-position))
                 (position start)
                 image-row-p)
            (while (and (< position newline) (not image-row-p))
              (if (get-text-property position 'epub-reader-image-slice)
                  (setq image-row-p t)
                (setq position
                      (or (next-single-property-change
                           position 'epub-reader-image-slice nil newline)
                          newline))))
            (when (and (< newline (point-max))
                       (= (char-after newline) ?\n))
              (remove-text-properties
               newline (1+ newline) '(line-height nil line-spacing nil))
              (if image-row-p
                  ;; This documented image-slice form also prevents newline
                  ;; font metrics from enlarging a zero-spacing image row.
                  (put-text-property newline (1+ newline) 'line-height t)
                (when epub-reader-ui--prose-line-spacing
                  (put-text-property
                   newline (1+ newline) 'line-spacing
                   epub-reader-ui--prose-line-spacing))))
            (forward-line 1))))))
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
         (index (plist-get textui-state :spine-index)))
    (textui-effect
     'epub-reader-post-render (list index available-width)
     (lambda ()
       (epub-reader-ui--post-render (current-buffer))))
    (textui-effect
     'epub-reader-background
     (list (epub-reader-publication-book-key publication))
     (lambda ()
       (setf (epub-reader-session-background-callback session)
             (textui-async-callback
              (lambda (generation)
                (epub-reader-ui--run-background-job session generation))))
       (lambda ()
         (epub-reader-ui--cancel-background-work session)
         (setf (epub-reader-session-background-callback session) nil))))
    (when (and epub-reader-enable-progress
               (epub-reader-session-store session))
      (textui-effect
       'epub-reader-progress-save
       (list (epub-reader-store-book-key
              (epub-reader-session-store session)))
       (lambda ()
         (setf (epub-reader-session-progress-callback session)
               (textui-async-callback
                (lambda ()
                  (setf (epub-reader-session-progress-timer session) nil)
                  (epub-reader-ui--save-progress-safely t))))
         (lambda ()
           (epub-reader-ui--cancel-progress-timer session)
           (setf (epub-reader-session-progress-callback session) nil)))))
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
  "Capture point and top semantic positions for all visible windows."
  (let ((index (epub-reader-ui--state-value :spine-index))
        viewports)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (when (window-live-p window)
        (let ((window-point (window-point window)))
          (push
           (epub-reader-viewport--create
            :window window
            :point-locator (epub-reader-locator-at-point
                            index window-point (current-buffer))
            :top-locator (epub-reader-locator-at-point
                          index (window-start window) (current-buffer))
            :visual-row (count-screen-lines
                         (window-start window) window-point nil window))
           viewports))))
    (epub-reader-view-state--create
     :point-locator (epub-reader-locator-at-point index)
     :viewports (nreverse viewports))))

(defun epub-reader-ui--restore-window-visual-row (window position desired-row)
  "Keep POSITION at DESIRED-ROW in WINDOW after a region refresh."
  (set-window-point window position)
  (let ((attempts 0)
        actual-row moved)
    (while (and (< attempts 100)
                (progn
                  (setq actual-row
                        (count-screen-lines
                         (window-start window) position nil window))
                  (/= actual-row desired-row)))
      (with-selected-window window
        (goto-char (window-start window))
        (setq moved
              (vertical-motion
               (if (> actual-row desired-row) 1 -1) window))
        (unless (= moved 0)
          (set-window-start window (point) t)))
      (set-window-point window position)
      (if (= moved 0)
          (setq attempts 100)
        (setq attempts (1+ attempts))))))

(defun epub-reader-ui--restore-view-state (view-state)
  "Restore semantic point and each window top from VIEW-STATE."
  (let* ((point-locator
          (epub-reader-view-state-point-locator view-state))
         (point-position
          (and point-locator (epub-reader-locator-point point-locator))))
    (when point-position
      (goto-char point-position))
    (dolist (viewport (epub-reader-view-state-viewports view-state))
      (let* ((window (epub-reader-viewport-window viewport))
             (point-locator (epub-reader-viewport-point-locator viewport))
             (top-locator (epub-reader-viewport-top-locator viewport))
             (position (and point-locator
                            (epub-reader-locator-point point-locator)))
             (top-position (and top-locator
                                (epub-reader-locator-point top-locator))))
        (when (and position (window-live-p window)
                   (eq (window-buffer window) (current-buffer)))
          (if top-position
              (set-window-start window top-position t)
            (with-selected-window window
              (goto-char position)
              (vertical-motion
               (- (epub-reader-viewport-visual-row viewport)) window)
              (set-window-start window (point) t)))
          ;; Selecting a window to run `vertical-motion' moves its point.
          ;; Restore the semantic point only after positioning its top row.
          ;; A resolved top locator or `vertical-motion' can be one display row
          ;; off when POSITION is inside a physically wrapped line.  Correct
          ;; from the current start until the captured visual metric matches.
          (epub-reader-ui--restore-window-visual-row
           window position (epub-reader-viewport-visual-row viewport)))))
    ;; `with-selected-window' above can leave the buffer point at a viewport's
    ;; temporary start position.  Semantic point is the final authority.
    (when point-position
      (goto-char point-position))))

(defun epub-reader-ui--refresh-for-text-scale ()
  "Reflow the complete reader after a buffer-local text-scale change.
Capture semantic positions before the full TextUI rebuild because scaling can
change both paragraph wrapping and the number of physical image slice rows."
  (when (and epub-reader-ui-mode
             (epub-reader-session-p epub-reader-ui--session)
             (not (epub-reader-session-refreshing-p
                   epub-reader-ui--session)))
    (let ((session epub-reader-ui--session)
          (buffer (current-buffer))
          (view-state (epub-reader-ui--capture-view-state)))
      (setf (epub-reader-session-refreshing-p session) t)
      (unwind-protect
          (progn
            (textui-refresh buffer)
            ;; The post-render effect has stable dependencies when only the
            ;; font changes, so reconcile the reader-owned properties here.
            (epub-reader-ui--post-render buffer)
            (epub-reader-ui--restore-view-state view-state)
            (force-mode-line-update t))
        (setf (epub-reader-session-refreshing-p session) nil)))))

(defun epub-reader-ui--refresh-chunk (start end)
  "Synchronously replace the chapter region with block range START to END.
Every source-order change captures and restores reader locators and visual
window rows; TextUI's internal focus identity is not an EPUB position."
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
            (epub-reader-ui--queue-image-job
             session (epub-reader-ui--state-value :spine-index) start end)
            (when view-state
              (epub-reader-ui--restore-view-state view-state)))
        (setf (epub-reader-session-refreshing-p session) nil)))
    buffer))

(defun epub-reader-ui--ensure-block-visible (block-index)
  "Refresh the current chunk if needed to include BLOCK-INDEX."
  (let* ((blocks
          (epub-reader-ui--current-blocks))
         (start (plist-get textui-state :chunk-start))
         (end (plist-get textui-state :chunk-end)))
    (unless (and (<= start block-index) (< block-index end))
      (pcase-let ((`(,next-start ,next-end)
                   (epub-reader-ui--chunk-range
                    blocks block-index 'scroll)))
        (epub-reader-ui--refresh-chunk next-start next-end)))))

(defun epub-reader-ui--inside-chunk-guard-p
    (block-index start end block-count)
  "Return non-nil when BLOCK-INDEX is in either inclusive chunk guard."
  (or (and (> start 0)
           (<= (- block-index start) epub-reader-chunk-guard-blocks))
      (and (< end block-count)
           (<= (- end block-index) epub-reader-chunk-guard-blocks))))

(defun epub-reader-ui--maybe-shift-chunk ()
  "Shift the chapter window when point approaches a rendered chunk edge."
  (when (and epub-reader-ui-mode
             (epub-reader-session-p epub-reader-ui--session)
             (not (epub-reader-session-refreshing-p epub-reader-ui--session)))
    (let* ((source (epub-reader-locator-source-at-point))
           (block-index
            (and source
                 (gethash
                  (aref source 1)
                  (epub-reader-ui--current-block-index))))
           (start (plist-get textui-state :chunk-start))
           (end (plist-get textui-state :chunk-end))
           (length (length
                    (epub-reader-ui--current-blocks))))
      (when (and block-index
                 (epub-reader-ui--inside-chunk-guard-p
                  block-index start end length))
        (pcase-let ((`(,next-start ,next-end)
                     (epub-reader-ui--chunk-range
                      (epub-reader-ui--current-blocks)
                      block-index 'scroll)))
          ;; A smaller range that adds no new source only discards context and
          ;; can make the captured visual row physically impossible to keep.
          (unless (and (>= next-start start) (<= next-end end))
            (epub-reader-ui--refresh-chunk next-start next-end)))))))

(defun epub-reader-ui--goto-start (&optional fragment)
  "Move to current chapter's FRAGMENT or first source position."
  (let* ((session (epub-reader-ui--current-session))
         (section (epub-reader-ui--current-section session))
         (block-index (and fragment
                           (gethash fragment
                                    (epub-reader-ui--current-anchor-index session))))
         (_visible (when block-index
                     (epub-reader-ui--ensure-block-visible block-index)))
         (position
          (or (epub-reader-ui--fragment-position
               (epub-reader-section-path section) fragment)
              (epub-reader-ui--first-source-position)
              (point-min))))
    (goto-char position)
    (epub-reader-ui--recenter-visible-windows)))

(defun epub-reader-ui--goto-block-index (block-index &optional at-end)
  "Move to semantic BLOCK-INDEX, optionally to its last source character."
  (let* ((session (epub-reader-ui--current-session))
         (block (aref (epub-reader-ui--current-blocks session) block-index))
         (key (epub-reader-block-key block)))
    (epub-reader-ui--ensure-block-visible block-index)
    (let ((position
           (if at-end
               (cl-loop for candidate downfrom (1- (point-max)) to (point-min)
                        for source = (get-text-property
                                      candidate 'epub-reader-source)
                        when (and (epub-reader-locator-source-p source)
                                  (equal (aref source 1) key))
                        return candidate)
             (let ((position (point-min)) found)
               (while (and (< position (point-max)) (not found))
                 (let ((source
                        (get-text-property position 'epub-reader-source)))
                   (when (and (epub-reader-locator-source-p source)
                              (equal (aref source 1) key))
                     (setq found position)))
                 (unless found (setq position (1+ position))))
               found))))
      (when position
        (goto-char position)
        (epub-reader-ui--recenter-visible-windows))
      position)))

(defun epub-reader-ui--refresh-toc-buffer ()
  "Refresh the session TOC buffer while preserving its selected row."
  (let ((toc-buffer
         (epub-reader-session-toc-buffer
          (epub-reader-ui--current-session))))
    (when (buffer-live-p toc-buffer)
      (with-current-buffer toc-buffer
        (epub-reader-toc--refresh)))))

(defun epub-reader-ui--switch-chapter
    (index &optional fragment no-history at-end)
  "Synchronously switch the current reader to spine INDEX and FRAGMENT."
  (let* ((buffer (current-buffer))
         (session (epub-reader-ui--current-session))
         (publication (epub-reader-session-publication session))
         (count (length (epub-reader-publication-spine publication))))
    (unless (and (>= index 0) (< index count))
      (user-error "No chapter in that direction"))
    (epub-reader-ui--cancel-background-work session)
    (epub-reader-ui--save-progress-safely t)
    (unless no-history
      (epub-reader-ui--record-history))
    (let* ((_chapter (epub-reader-ui--load-chapter session index))
           (target (or (and fragment
                            (gethash
                             fragment
                             (epub-reader-ui--current-anchor-index session)))
                       0))
           (range
            (epub-reader-ui--chunk-range
             (epub-reader-ui--current-blocks session) target 'first)))
      (textui-update
       buffer
       (lambda (state)
         (let ((next (copy-sequence state)))
           (setq next (plist-put next :spine-index index))
           (epub-reader-ui--state-with-chunk
            next (car range) (cadr range)))))
      (textui-refresh buffer)
      (if at-end
          (epub-reader-ui--goto-block-index
           (1- (length (epub-reader-ui--current-blocks session))) t)
        (epub-reader-ui--goto-start fragment))
      (epub-reader-ui--observe-progress t)
      (epub-reader-ui--refresh-toc-buffer)
      (epub-reader-ui--schedule-background-work session index)
      (force-mode-line-update t)
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

(defun epub-reader-ui--goto-locator (locator)
  "Navigate to persisted LOCATOR without adding another history entry."
  (let* ((session (epub-reader-ui--current-session))
         (publication (epub-reader-session-publication session))
         (index
          (epub-reader-ui--spine-index-for-path
           publication (epub-reader-locator-path locator))))
    (unless index
      (user-error "History target is no longer in the reading spine"))
    (unless (= index (epub-reader-ui--state-value :spine-index))
      (epub-reader-ui--switch-chapter index nil t))
    (epub-reader-ui--ensure-block-visible
     (epub-reader-ui--restore-target-index session locator))
    (let ((resolution (epub-reader-locator-goto locator)))
      (unless (epub-reader-locator-resolution-position resolution)
        (user-error "History position could not be restored"))
      (epub-reader-ui--recenter-visible-windows)
      resolution)))

(defun epub-reader-history-back ()
  "Return to the previous semantic navigation position."
  (interactive)
  (let* ((session (epub-reader-ui--current-session))
         (stack (epub-reader-session-history-back session)))
    (unless stack (user-error "No earlier EPUB location"))
    (let ((current (epub-reader-ui--current-locator))
          (target (car stack)))
      (setf (epub-reader-session-history-back session) (cdr stack))
      (when current
        (push current (epub-reader-session-history-forward session)))
      (epub-reader-ui--goto-locator target))))

(defun epub-reader-history-forward ()
  "Move forward after `epub-reader-history-back'."
  (interactive)
  (let* ((session (epub-reader-ui--current-session))
         (stack (epub-reader-session-history-forward session)))
    (unless stack (user-error "No later EPUB location"))
    (let ((current (epub-reader-ui--current-locator))
          (target (car stack)))
      (setf (epub-reader-session-history-forward session) (cdr stack))
      (when current
        (push current (epub-reader-session-history-back session)))
      (epub-reader-ui--goto-locator target))))

(defun epub-reader-scroll-forward ()
  "Scroll forward, shifting chunks or advancing at chapter end."
  (interactive)
  (condition-case nil
      (scroll-up-command)
    (end-of-buffer
     (let* ((session (epub-reader-ui--current-session))
            (blocks (epub-reader-ui--current-blocks session))
            (end (plist-get textui-state :chunk-end))
            (index (epub-reader-ui--state-value :spine-index))
            (count (length
                    (epub-reader-publication-spine
                     (epub-reader-session-publication session)))))
       (cond
        ((< end (length blocks))
         (epub-reader-ui--goto-block-index end))
        ((< (1+ index) count)
         (epub-reader-ui--switch-chapter (1+ index)))
        (t (user-error "End of publication"))))))
  (epub-reader-ui--maybe-shift-chunk))

(defun epub-reader-scroll-backward ()
  "Scroll backward, shifting chunks or moving to the previous chapter end."
  (interactive)
  (condition-case nil
      (scroll-down-command)
    (beginning-of-buffer
     (let ((start (plist-get textui-state :chunk-start))
           (index (epub-reader-ui--state-value :spine-index)))
       (cond
        ((> start 0)
         (epub-reader-ui--goto-block-index (1- start) t))
        ((> index 0)
         (epub-reader-ui--switch-chapter (1- index) nil nil t))
        (t (user-error "Beginning of publication"))))))
  (epub-reader-ui--maybe-shift-chunk))

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

(defun epub-reader-ui--jump-to-target (path fragment)
  "Navigate current reader to spine PATH and optional FRAGMENT."
  (let* ((session (epub-reader-ui--current-session))
         (publication (epub-reader-session-publication session))
         (index (epub-reader-ui--spine-index-for-path publication path)))
    (unless index
      (user-error "TOC target is not in the reading spine: %s" path))
    (if (= index (epub-reader-ui--state-value :spine-index))
        (progn
          (epub-reader-ui--record-history)
          (epub-reader-ui--goto-start fragment))
      (epub-reader-ui--switch-chapter index fragment))))

(defun epub-reader-toc--reader-session ()
  "Return the live reader session controlled by the current TOC buffer."
  (unless (buffer-live-p epub-reader-toc--reader-buffer)
    (user-error "The EPUB reader buffer has been closed"))
  (with-current-buffer epub-reader-toc--reader-buffer
    (epub-reader-ui--current-session)))

(defun epub-reader-toc--rows
    (entries collapsed current-path &optional prefix depth)
  "Flatten visible ENTRIES using COLLAPSED keys and CURRENT-PATH."
  (let ((depth (or depth 0))
        rows)
    (cl-loop
     for entry in entries
     for index from 0
     for key = (if prefix (format "%s/%d" prefix index)
                 (number-to-string index))
     for children = (epub-reader-toc-entry-children entry)
     for collapsed-p = (member key collapsed)
     do (push
         (epub-reader-toc-row--create
          :key key :entry entry :depth depth
          :expanded-p (and children (not collapsed-p))
          :current-p (and (epub-reader-toc-entry-path entry)
                          (equal (epub-reader-toc-entry-path entry)
                                 current-path)))
         rows)
     when (and children (not collapsed-p))
     do (setq rows
              (nconc
               (nreverse
                (epub-reader-toc--rows
                 children collapsed current-path key (1+ depth)))
               rows)))
    (nreverse rows)))

(defun epub-reader-toc--row-element (row)
  "Return one TextUI text element for TOC ROW."
  (let* ((entry (epub-reader-toc-row-entry row))
         (children (epub-reader-toc-entry-children entry))
         (disclosure (cond ((not children) "  ")
                           ((epub-reader-toc-row-expanded-p row) "▾ ")
                           (t "▸ ")))
         (current (if (epub-reader-toc-row-current-p row) "▶ " "  "))
         (value
          (propertize
           (format "%s%s%s%s" current
                   (make-string (* 2 (epub-reader-toc-row-depth row)) ?\s)
                   disclosure (epub-reader-toc-entry-label entry))
           'epub-reader-toc-row row
           'epub-reader-toc-key (epub-reader-toc-row-key row)
           'face (cond ((epub-reader-toc-row-current-p row)
                        'epub-reader-toc-current-face)
                       ((and children
                             (not (epub-reader-toc-entry-path entry)))
                        'epub-reader-toc-group-face)
                       (t 'default))
           'mouse-face 'highlight
           'help-echo (if (epub-reader-toc-entry-path entry)
                          "RET: jump; TAB: fold"
                        "RET/TAB: fold"))))
    (list :type :text :value value)))

(defun epub-reader-toc-frame (_available-width)
  "Return the secondary TextUI table-of-contents frame."
  (let* ((session (epub-reader-toc--reader-session))
         (publication (epub-reader-session-publication session))
         (current-path (epub-reader-section-path
                        (epub-reader-ui--current-section session)))
         (rows
          (epub-reader-toc--rows
           (epub-reader-publication-toc publication)
           (plist-get textui-state :collapsed) current-path)))
    (list
     (list :type :flex :direction :column :gap 0
           :children (mapcar #'epub-reader-toc--row-element rows)))))

(defun epub-reader-toc--row-at-point ()
  "Return the TOC row at or immediately before point."
  (or (get-text-property (point) 'epub-reader-toc-row)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'epub-reader-toc-row))))

(defun epub-reader-toc--key-position (key)
  "Return buffer position of visible TOC row KEY."
  (cl-loop for position from (point-min) below (point-max)
           when (equal (get-text-property position 'epub-reader-toc-key) key)
           return position))

(defun epub-reader-toc--fallback-position (key)
  "Return visible position for KEY, an ancestor, current row, or first row."
  (let ((candidate key)
        position)
    (while (and candidate (not position))
      (setq position (epub-reader-toc--key-position candidate))
      (unless position
        (setq candidate
              (and (string-match "\\`\\(.*\\)/[^/]+\\'" candidate)
                   (match-string 1 candidate)))))
    (or position
        (cl-loop for cursor from (point-min) below (point-max)
                 for row = (get-text-property cursor 'epub-reader-toc-row)
                 when (and row (epub-reader-toc-row-current-p row))
                 return cursor)
        (epub-reader-toc--key-position "0"))))

(defun epub-reader-toc--restore-selection (&optional window)
  "Restore the stable selected row and optional WINDOW point."
  (let* ((requested (plist-get textui-state :selected-key))
         (position (epub-reader-toc--fallback-position requested)))
    (when position
      (goto-char position)
      (let ((actual (get-text-property position 'epub-reader-toc-key)))
        (setq textui-state
              (plist-put (copy-sequence textui-state)
                         :selected-key actual)))
      (when (window-live-p window)
        (set-window-point window position)))
    position))

(defun epub-reader-toc--refresh ()
  "Refresh current TOC and preserve point by stable row key."
  (let* ((row (epub-reader-toc--row-at-point))
         (key (or (and row (epub-reader-toc-row-key row))
                  (plist-get textui-state :selected-key))))
    (setq textui-state
          (plist-put (copy-sequence textui-state) :selected-key key))
    (textui-refresh (current-buffer))
    (epub-reader-toc--restore-selection
     (get-buffer-window (current-buffer) t))))

(defun epub-reader-toc-quit ()
  "Hide the TOC after saving its selected stable row key."
  (interactive)
  (let ((row (epub-reader-toc--row-at-point)))
    (when row
      (setq textui-state
            (plist-put (copy-sequence textui-state) :selected-key
                       (epub-reader-toc-row-key row)))))
  (delete-windows-on (current-buffer) t))

(defun epub-reader-toc-toggle ()
  "Toggle the TOC subtree at point."
  (interactive)
  (let* ((row (epub-reader-toc--row-at-point))
         (entry (and row (epub-reader-toc-row-entry row))))
    (unless (and row (epub-reader-toc-entry-children entry))
      (user-error "TOC entry has no children"))
    (let* ((key (epub-reader-toc-row-key row))
           (collapsed (copy-sequence (plist-get textui-state :collapsed))))
      (setq textui-state
            (plist-put
             (copy-sequence textui-state) :collapsed
             (if (member key collapsed)
                 (delete key collapsed)
               (cons key collapsed))))
      (epub-reader-toc--refresh))))

(defun epub-reader-toc-activate ()
  "Jump to the TOC target at point, or fold a targetless group."
  (interactive)
  (let* ((row (epub-reader-toc--row-at-point))
         (entry (and row (epub-reader-toc-row-entry row))))
    (unless row (user-error "No TOC entry at point"))
    (if (not (epub-reader-toc-entry-path entry))
        (epub-reader-toc-toggle)
      (with-current-buffer epub-reader-toc--reader-buffer
        (epub-reader-ui--jump-to-target
         (epub-reader-toc-entry-path entry)
         (epub-reader-toc-entry-fragment entry))))))

(defun epub-reader-toc ()
  "Display this reader's hierarchical TextUI table of contents."
  (interactive)
  (let* ((reader (current-buffer))
         (session (epub-reader-ui--current-session))
         (existing (epub-reader-session-toc-buffer session)))
    (if (buffer-live-p existing)
        (let ((_hidden (delete-windows-on existing t))
              (window
               (display-buffer existing '(display-buffer-in-side-window
                                          (side . left)
                                          (window-width . 34)))))
          (with-current-buffer existing
            (epub-reader-toc--restore-selection window))
          existing)
      (let* ((epub-reader-toc--reader-buffer reader)
            (buffer
             (textui-open
              (generate-new-buffer-name
               (format "*EPUB TOC: %s*"
                       (epub-reader-publication-title
                        (epub-reader-session-publication session))))
              #'epub-reader-toc-frame
              '(:collapsed nil :selected-key nil))))
        (with-current-buffer buffer
          (setq-local epub-reader-toc--reader-buffer reader)
          (epub-reader-toc-mode 1))
        (setf (epub-reader-session-toc-buffer session) buffer)
        ;; `textui-open' may choose an ordinary display window.  The reader
        ;; owns the sole TOC presentation and always recreates it at the side.
        (delete-windows-on buffer t)
        (let ((window
               (display-buffer buffer '(display-buffer-in-side-window
                                        (side . left) (window-width . 34)))))
          (with-current-buffer buffer
            (epub-reader-toc--restore-selection window)))
        buffer))))

(defun epub-reader-ui--completion-entries (entries &optional prefix)
  "Return flattened completion alist for target-bearing ENTRIES."
  (cl-mapcan
   (lambda (entry)
     (let* ((label (epub-reader-toc-entry-label entry))
            (qualified (if prefix (format "%s / %s" prefix label) label)))
       (append
        (and (epub-reader-toc-entry-path entry)
             (list (cons qualified entry)))
        (epub-reader-ui--completion-entries
         (epub-reader-toc-entry-children entry) qualified))))
   entries))

(defun epub-reader-jump ()
  "Jump to an EPUB TOC/title target using `completing-read'."
  (interactive)
  (let* ((publication
          (epub-reader-session-publication (epub-reader-ui--current-session)))
         (entries
          (epub-reader-ui--completion-entries
           (epub-reader-publication-toc publication)))
         (choice (completing-read "EPUB target: " entries nil t))
         (entry (cdr (assoc choice entries))))
    (epub-reader-ui--jump-to-target
     (epub-reader-toc-entry-path entry)
     (epub-reader-toc-entry-fragment entry))))

(defun epub-reader-ui--short-text (text length)
  "Return whitespace-normalized TEXT truncated to LENGTH characters."
  (let ((clean (string-trim
                (replace-regexp-in-string
                 "[[:space:]\n]+" " " (substring-no-properties text)))))
    (if (> (length clean) length)
        (concat (substring clean 0 length) "…")
      clean)))

(defun epub-reader-ui--preview-for-locator (session locator)
  "Return a short canonical paragraph preview for LOCATOR in SESSION."
  (let ((block-index
         (gethash (epub-reader-locator-block locator)
                  (epub-reader-ui--current-block-index session))))
    (if block-index
        (epub-reader-ui--short-text
         (epub-reader-block-text
          (aref (epub-reader-ui--current-blocks session) block-index))
         48)
      (epub-reader-ui--short-text
       (or (epub-reader-locator-context locator) "Bookmark") 48))))

(defun epub-reader-add-bookmark (&optional name)
  "Add a bookmark at point, prompting for its optional short NAME."
  (interactive)
  (let* ((session (epub-reader-ui--current-session))
         (locator (epub-reader-ui--current-locator)))
    (unless locator (user-error "Point is outside EPUB content"))
    (let* ((preview (epub-reader-ui--preview-for-locator session locator))
           (default-name (epub-reader-ui--short-text preview 18))
           (chosen (or name (read-string "Bookmark name: " default-name)))
           (bookmark
            (epub-reader-bookmark-create
             (epub-reader-locator-book-key locator)
             (if (string-empty-p chosen) default-name chosen)
             preview locator)))
      (epub-reader-store-stage-bookmark
       (epub-reader-session-store session)
       (epub-reader-bookmark-to-plist bookmark))
      (push bookmark (epub-reader-session-bookmarks session))
      (epub-reader-ui--flush-reader-marks session)
      (epub-reader-ui--refresh-live-bookmark-list session)
      (message "Bookmark saved: %s" (epub-reader-bookmark-name bookmark))
      bookmark)))

(defun epub-reader-bookmark-list--session ()
  "Return the live reader session owned by this bookmark list."
  (unless (buffer-live-p epub-reader-bookmark-list--reader-buffer)
    (user-error "The EPUB reader buffer has been closed"))
  (with-current-buffer epub-reader-bookmark-list--reader-buffer
    (epub-reader-ui--current-session)))

(defun epub-reader-bookmark-list-frame (_available-width)
  "Return the TextUI frame for the current book's bookmarks."
  (let* ((session (epub-reader-bookmark-list--session))
         (publication (epub-reader-session-publication session))
         (bookmarks
          (sort (copy-sequence (epub-reader-session-bookmarks session))
                (lambda (left right)
                  (< (epub-reader-bookmark-created left)
                     (epub-reader-bookmark-created right)))))
         (children
          (list
           (list :type :text
                 :value (propertize
                         (format "%s — Bookmarks"
                                 (epub-reader-publication-title publication))
                         'face 'epub-reader-header-face)))))
    (if bookmarks
        (dolist (bookmark bookmarks)
          (let* ((locator (epub-reader-bookmark-locator bookmark))
                 (value
                  (propertize
                   (format "%d. %s — %s"
                           (1+ (epub-reader-locator-spine-index locator))
                           (epub-reader-bookmark-name bookmark)
                           (epub-reader-bookmark-preview bookmark))
                   'epub-reader-bookmark bookmark
                   'mouse-face 'highlight
                   'help-echo "RET: jump; d: delete")))
            (setq children
                  (append children (list (list :type :text :value value))))))
      (setq children
            (append children
                    (list (list :type :text
                                :value (propertize
                                        "No bookmarks yet" 'face 'shadow))))))
    (list (list :type :flex :direction :column :gap 1
                :children children))))

(defun epub-reader-bookmark-list--at-point ()
  "Return the bookmark at or immediately before point."
  (or (get-text-property (point) 'epub-reader-bookmark)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'epub-reader-bookmark))))

(defun epub-reader-bookmark-list--refresh (&optional selected-id)
  "Refresh the current bookmark list and restore SELECTED-ID when visible."
  (textui-refresh (current-buffer))
  (when selected-id
    (let ((position
           (cl-loop for cursor from (point-min) below (point-max)
                    for bookmark = (get-text-property
                                    cursor 'epub-reader-bookmark)
                    when (and bookmark
                              (equal (epub-reader-bookmark-id bookmark)
                                     selected-id))
                    return cursor)))
      (when position (goto-char position)))))

(defun epub-reader-ui--refresh-live-bookmark-list
    (session &optional selected-id)
  "Refresh SESSION's live bookmark list, preserving SELECTED-ID."
  (let ((buffer (epub-reader-session-bookmark-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (epub-reader-bookmark-list--refresh selected-id)))))

(defun epub-reader-bookmark-list-activate ()
  "Jump to the bookmark at point."
  (interactive)
  (let ((bookmark (epub-reader-bookmark-list--at-point))
        (reader epub-reader-bookmark-list--reader-buffer))
    (unless bookmark (user-error "No bookmark at point"))
    (with-current-buffer reader
      (epub-reader-ui--record-history)
      (epub-reader-ui--goto-locator (epub-reader-bookmark-locator bookmark)))
    (pop-to-buffer reader)))

(defun epub-reader-bookmark-list-delete ()
  "Delete the bookmark at point from the sidecar."
  (interactive)
  (let* ((bookmark (epub-reader-bookmark-list--at-point))
         (session (epub-reader-bookmark-list--session)))
    (unless bookmark (user-error "No bookmark at point"))
    (epub-reader-store-delete-bookmark
     (epub-reader-session-store session) (epub-reader-bookmark-id bookmark))
    (setf (epub-reader-session-bookmarks session)
          (cl-delete (epub-reader-bookmark-id bookmark)
                     (epub-reader-session-bookmarks session)
                     :key #'epub-reader-bookmark-id :test #'equal))
    (epub-reader-ui--flush-reader-marks session)
    (epub-reader-bookmark-list--refresh)))

(defun epub-reader-bookmark-list-quit ()
  "Hide the bookmark list."
  (interactive)
  (delete-windows-on (current-buffer) t))

(defun epub-reader-bookmarks ()
  "Display this book's bookmarks in a secondary TextUI buffer."
  (interactive)
  (let* ((reader (current-buffer))
         (session (epub-reader-ui--current-session))
         (existing (epub-reader-session-bookmark-buffer session)))
    (if (buffer-live-p existing)
        (let ((selected
               (with-current-buffer existing
                 (epub-reader-bookmark-list--at-point))))
          (epub-reader-ui--refresh-live-bookmark-list
           session (and selected (epub-reader-bookmark-id selected)))
          (display-buffer existing)
          existing)
      (let* ((epub-reader-bookmark-list--reader-buffer reader)
             (buffer
              (textui-open
               (generate-new-buffer-name
                (format "*EPUB Bookmarks: %s*"
                        (epub-reader-publication-title
                         (epub-reader-session-publication session))))
               #'epub-reader-bookmark-list-frame nil)))
        (with-current-buffer buffer
          (setq-local epub-reader-bookmark-list--reader-buffer reader)
          (epub-reader-bookmark-list-mode 1))
        (setf (epub-reader-session-bookmark-buffer session) buffer)
        buffer))))

(defun epub-reader-add-highlight (start end)
  "Highlight the source text in the active region from START to END."
  (interactive "r")
  (unless (use-region-p)
    (user-error "Select EPUB text before adding a highlight"))
  (let* ((session (epub-reader-ui--current-session))
         (range (epub-reader-locator-range-capture
                 start end (epub-reader-ui--state-value :spine-index)
                 nil
                 (epub-reader-chapter-data-locator-index
                  (epub-reader-ui--current-chapter session))))
         (annotation
          (epub-reader-annotation-create
           (epub-reader-publication-book-key
            (epub-reader-session-publication session))
           range)))
    (epub-reader-store-stage-annotation
     (epub-reader-session-store session)
     (epub-reader-annotation-to-plist annotation))
    (push annotation (epub-reader-session-annotations session))
    (epub-reader-ui--flush-reader-marks session)
    (deactivate-mark)
    (epub-reader-ui--refresh-chunk
     (plist-get textui-state :chunk-start)
     (plist-get textui-state :chunk-end))
    (epub-reader-ui--refresh-live-annotation-list session)
    (message "Highlight saved")
    annotation))

(defun epub-reader-ui--annotation-by-id (session id)
  "Return SESSION annotation identified by ID."
  (cl-find id (epub-reader-session-annotations session)
           :key #'epub-reader-annotation-id :test #'equal))

(defun epub-reader-ui--annotation-at-point (session)
  "Return the annotation selected by source properties at point in SESSION."
  (let ((ids (or (get-text-property (point) 'epub-reader-annotation-ids)
                 (and (> (point) (point-min))
                      (get-text-property
                       (1- (point)) 'epub-reader-annotation-ids)))))
    (cond
     ((null ids) nil)
     ((null (cdr ids)) (epub-reader-ui--annotation-by-id session (car ids)))
     (t
      (let* ((choices
              (mapcar
               (lambda (id)
                 (let* ((annotation
                         (epub-reader-ui--annotation-by-id session id))
                        (quote
                         (and annotation
                              (epub-reader-locator-range-exact
                               (epub-reader-annotation-range annotation)))))
                   (cons (format "%s — %s" (substring id 0 (min 8 (length id)))
                                 (epub-reader-ui--short-text (or quote "") 36))
                         annotation)))
               ids))
             (choice (completing-read "Annotation: " choices nil t)))
        (cdr (assoc choice choices)))))))

(defun epub-reader-ui--set-annotation-note (session annotation note)
  "Set ANNOTATION's NOTE, persist it through SESSION, and return it."
  (setf (epub-reader-annotation-note annotation) note)
  (epub-reader-store-stage-annotation
   (epub-reader-session-store session)
   (epub-reader-annotation-to-plist annotation))
  (epub-reader-ui--flush-reader-marks session)
  annotation)

(defun epub-reader-edit-note ()
  "View or edit the note attached to the highlight at point."
  (interactive)
  (let* ((session (epub-reader-ui--current-session))
         (annotation (epub-reader-ui--annotation-at-point session)))
    (unless annotation (user-error "Point is not on an EPUB highlight"))
    (epub-reader-ui--set-annotation-note
     session annotation
     (read-string "Highlight note: " (epub-reader-annotation-note annotation)))
    (epub-reader-ui--refresh-chunk
     (plist-get textui-state :chunk-start)
     (plist-get textui-state :chunk-end))
    (epub-reader-ui--refresh-live-annotation-list
     session (epub-reader-annotation-id annotation))
    (message "Highlight note saved")))

(defun epub-reader-ui--resolve-annotation (session annotation)
  "Resolve ANNOTATION against its canonical chapter in SESSION."
  (let* ((range (epub-reader-annotation-range annotation))
         (start (epub-reader-locator-range-start range))
         (index
          (epub-reader-ui--spine-index-for-path
           (epub-reader-session-publication session)
           (epub-reader-locator-path start)))
         (resolution
          (if index
              (epub-reader-locator-range-resolve
               range
               (epub-reader-chapter-data-locator-index
                (epub-reader-ui--chapter-data session index)))
            (epub-reader-locator-range-unresolved 'identity-mismatch))))
    (setf (epub-reader-annotation-quality annotation)
          (epub-reader-locator-range-resolution-quality resolution))
    resolution))

(defun epub-reader-ui--goto-annotation (annotation)
  "Navigate the current reader to ANNOTATION and return its resolution."
  (let* ((session (epub-reader-ui--current-session))
         (range (epub-reader-annotation-range annotation))
         (start (epub-reader-locator-range-start range))
         (publication (epub-reader-session-publication session))
         (index (epub-reader-ui--spine-index-for-path
                 publication (epub-reader-locator-path start))))
    (unless index (user-error "Annotation chapter is no longer in this book"))
    (if (= index (epub-reader-ui--state-value :spine-index))
        (epub-reader-ui--record-history)
      (epub-reader-ui--switch-chapter index))
    (let* ((resolution (epub-reader-ui--resolve-annotation
                        session annotation))
           (span (car (epub-reader-locator-range-resolution-spans resolution))))
      (epub-reader-ui--refresh-live-annotation-list
       session (epub-reader-annotation-id annotation))
      (unless span (user-error "Annotation text could not be found"))
      (let ((block-index
             (gethash (car span) (epub-reader-ui--current-block-index session))))
        (unless block-index (user-error "Annotation block could not be found"))
        (epub-reader-ui--ensure-block-visible block-index))
      (let* ((id (epub-reader-annotation-id annotation))
             (matching-source-p
              (lambda (cursor)
                (let ((source (get-text-property
                               cursor 'epub-reader-source)))
                  (and (epub-reader-locator-source-p source)
                       (equal (aref source 1) (car span))
                       (= (aref source 2) (nth 1 span))))))
             ;; Image leaves and their visible alt caption share a source
             ;; anchor.  Prefer the painted text run; fall back to the source
             ;; position for ordinary exact ranges.
             (position
              (or
               (cl-loop for cursor from (point-min) below (point-max)
                        when (and (funcall matching-source-p cursor)
                                  (member id (get-text-property
                                              cursor
                                              'epub-reader-annotation-ids)))
                        return cursor)
               (cl-loop for cursor from (point-min) below (point-max)
                        when (funcall matching-source-p cursor)
                        return cursor))))
        (unless position (user-error "Annotation is outside the rendered chunk"))
        (goto-char position)
        (epub-reader-ui--recenter-visible-windows)
        (unless (eq (epub-reader-locator-range-resolution-quality resolution)
                    'exact)
          (message "Highlight restored from quoted text; review its position"))
        resolution))))

(defun epub-reader-annotation-list--session ()
  "Return the live reader session owned by this annotation list."
  (unless (buffer-live-p epub-reader-annotation-list--reader-buffer)
    (user-error "The EPUB reader buffer has been closed"))
  (with-current-buffer epub-reader-annotation-list--reader-buffer
    (epub-reader-ui--current-session)))

(defun epub-reader-annotation-list-frame (_available-width)
  "Return annotations grouped by chapter as a TextUI frame."
  (let* ((session (epub-reader-annotation-list--session))
         (publication (epub-reader-session-publication session))
         (annotations
          (sort (copy-sequence (epub-reader-session-annotations session))
                (lambda (left right)
                  (let ((left-start (epub-reader-locator-range-start
                                     (epub-reader-annotation-range left)))
                        (right-start (epub-reader-locator-range-start
                                      (epub-reader-annotation-range right))))
                    (if (= (epub-reader-locator-spine-index left-start)
                           (epub-reader-locator-spine-index right-start))
                        (< (epub-reader-annotation-created left)
                           (epub-reader-annotation-created right))
                      (< (epub-reader-locator-spine-index left-start)
                         (epub-reader-locator-spine-index right-start)))))))
         (children
          (list (list :type :text
                      :value
                      (propertize
                       (format "%s — Highlights"
                               (epub-reader-publication-title publication))
                       'face 'epub-reader-header-face))))
         previous-index)
    (dolist (annotation annotations)
      (epub-reader-ui--resolve-annotation session annotation)
      (let* ((range (epub-reader-annotation-range annotation))
             (index (epub-reader-locator-spine-index
                     (epub-reader-locator-range-start range))))
        (unless (equal index previous-index)
          (setq children
                (append children
                        (list (list :type :text
                                    :value
                                    (propertize
                                     (format "Chapter %d" (1+ index))
                                     'face 'epub-reader-toc-group-face)))))
          (setq previous-index index))
        (let* ((note (epub-reader-annotation-note annotation))
               (warning
                (if (not (eq (epub-reader-annotation-quality annotation)
                             'exact))
                    "⚠ " ""))
               (value
                (propertize
                 (format "%s“%s”%s" warning
                         (epub-reader-ui--short-text
                          (epub-reader-locator-range-exact range) 60)
                         (if (string-empty-p note) ""
                           (format " — %s"
                                   (epub-reader-ui--short-text note 48))))
                 'epub-reader-annotation annotation
                 'mouse-face 'highlight
                 'help-echo "RET: jump; d: delete; e: edit note")))
          (setq children
                (append children (list (list :type :text :value value)))))))
    (unless annotations
      (setq children
            (append children
                    (list (list :type :text
                                :value (propertize
                                        "No highlights yet" 'face 'shadow))))))
    (list (list :type :flex :direction :column :gap 1
                :children children))))

(defun epub-reader-annotation-list--at-point ()
  "Return the annotation at or immediately before point."
  (or (get-text-property (point) 'epub-reader-annotation)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'epub-reader-annotation))))

(defun epub-reader-annotation-list--refresh (&optional selected-id)
  "Refresh this annotation list, restoring SELECTED-ID when present."
  (textui-refresh (current-buffer))
  (when selected-id
    (let ((position
           (cl-loop for cursor from (point-min) below (point-max)
                    for annotation = (get-text-property
                                      cursor 'epub-reader-annotation)
                    when (and annotation
                              (equal (epub-reader-annotation-id annotation)
                                     selected-id))
                    return cursor)))
      (when position (goto-char position)))))

(defun epub-reader-ui--refresh-live-annotation-list
    (session &optional selected-id)
  "Refresh SESSION's live annotation list, preserving SELECTED-ID."
  (let ((buffer (epub-reader-session-annotation-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (epub-reader-annotation-list--refresh selected-id)))))

(defun epub-reader-annotation-list-activate ()
  "Jump to the annotation at point."
  (interactive)
  (let ((annotation (epub-reader-annotation-list--at-point))
        (reader epub-reader-annotation-list--reader-buffer))
    (unless annotation (user-error "No annotation at point"))
    (with-current-buffer reader
      (epub-reader-ui--goto-annotation annotation))
    (pop-to-buffer reader)))

(defun epub-reader-annotation-list-delete ()
  "Delete the annotation at point from the sidecar and reader."
  (interactive)
  (let* ((annotation (epub-reader-annotation-list--at-point))
         (reader epub-reader-annotation-list--reader-buffer)
         (session (epub-reader-annotation-list--session)))
    (unless annotation (user-error "No annotation at point"))
    (epub-reader-store-delete-annotation
     (epub-reader-session-store session)
     (epub-reader-annotation-id annotation))
    (setf (epub-reader-session-annotations session)
          (cl-delete (epub-reader-annotation-id annotation)
                     (epub-reader-session-annotations session)
                     :key #'epub-reader-annotation-id :test #'equal))
    (epub-reader-ui--flush-reader-marks session)
    (with-current-buffer reader
      (epub-reader-ui--refresh-chunk
       (plist-get textui-state :chunk-start)
       (plist-get textui-state :chunk-end)))
    (epub-reader-annotation-list--refresh)))

(defun epub-reader-annotation-list-edit-note ()
  "Edit the note for the annotation at point."
  (interactive)
  (let* ((annotation (epub-reader-annotation-list--at-point))
         (reader epub-reader-annotation-list--reader-buffer)
         (session (epub-reader-annotation-list--session)))
    (unless annotation (user-error "No annotation at point"))
    (epub-reader-ui--set-annotation-note
     session annotation
     (read-string "Highlight note: " (epub-reader-annotation-note annotation)))
    (with-current-buffer reader
      (epub-reader-ui--refresh-chunk
       (plist-get textui-state :chunk-start)
       (plist-get textui-state :chunk-end)))
    (epub-reader-annotation-list--refresh
     (epub-reader-annotation-id annotation))))

(defun epub-reader-annotation-list-quit ()
  "Hide the annotation list."
  (interactive)
  (delete-windows-on (current-buffer) t))

(defun epub-reader-annotations ()
  "Display this book's highlights and notes in a TextUI buffer."
  (interactive)
  (let* ((reader (current-buffer))
         (session (epub-reader-ui--current-session))
         (existing (epub-reader-session-annotation-buffer session)))
    (if (buffer-live-p existing)
        (let ((selected
               (with-current-buffer existing
                 (epub-reader-annotation-list--at-point))))
          (epub-reader-ui--refresh-live-annotation-list
           session (and selected (epub-reader-annotation-id selected)))
          (display-buffer existing)
          existing)
      (let* ((epub-reader-annotation-list--reader-buffer reader)
             (buffer
              (textui-open
               (generate-new-buffer-name
                (format "*EPUB Highlights: %s*"
                        (epub-reader-publication-title
                         (epub-reader-session-publication session))))
               #'epub-reader-annotation-list-frame nil)))
        (with-current-buffer buffer
          (setq-local epub-reader-annotation-list--reader-buffer reader)
          (epub-reader-annotation-list-mode 1))
        (setf (epub-reader-session-annotation-buffer session) buffer)
        buffer))))

(defun epub-reader-follow-link ()
  "Follow the EPUB hyperlink at point."
  (interactive)
  (let ((href (epub-reader-ui--href-at-point)))
    (unless href
      (user-error "No EPUB link at point"))
    (let* ((session (epub-reader-ui--current-session))
           (publication (epub-reader-session-publication session))
           (current-index (epub-reader-ui--state-value :spine-index))
           (section (epub-reader-ui--current-section session))
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
              (let* ((_history (epub-reader-ui--record-history))
                     (block-index
                      (and (epub-reader-link-target-fragment target)
                           (gethash
                            (epub-reader-link-target-fragment target)
                            (epub-reader-ui--current-anchor-index session))))
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
  "Close the current EPUB reader buffer and release its publication.
When the book took over the frame on opening, bring back the window layout
that was in place before it was opened."
  (interactive)
  (let ((configuration epub-reader-ui--window-configuration))
    (when (and (kill-buffer (current-buffer))
               (window-configuration-p configuration)
               (frame-live-p (window-configuration-frame configuration)))
      (set-window-configuration configuration))))

(defun epub-reader-ui-open-and-display (file)
  "Open EPUB FILE, display its reader buffer, and return that buffer.
With `epub-reader-open-full-frame' non-nil the reader fills the selected frame
and remembers the previous window layout for `epub-reader-quit'."
  (let* ((configuration (and epub-reader-open-full-frame
                             (current-window-configuration)))
         (buffer (epub-reader-ui-open file)))
    (when configuration
      (pop-to-buffer-same-window buffer)
      (let ((window (get-buffer-window buffer)))
        (when window
          (condition-case nil
              (delete-other-windows window)
            (error nil))
          (select-window window)))
      (with-current-buffer buffer
        (setq epub-reader-ui--window-configuration configuration)))
    buffer))

(defun epub-reader-ui-open (file)
  "Open EPUB FILE in a new TextUI reader buffer and return that buffer."
  (let ((publication nil)
        (session nil)
        (buffer nil)
        succeeded)
    (unwind-protect
        (progn
          (setq publication (epub-reader-publication-open file))
          (let* ((store
                  (epub-reader-store-open
                   file (epub-reader-publication-book-key publication)))
                 (saved-locator
                  (and epub-reader-enable-progress
                       (epub-reader-store-load-locator store)))
                 (bookmarks
                  (epub-reader-ui--decode-values
                   (epub-reader-store-load-bookmarks store)
                   #'epub-reader-bookmark-from-plist "bookmark"))
                 (annotations
                  (epub-reader-ui--decode-values
                   (epub-reader-store-load-annotations store)
                   #'epub-reader-annotation-from-plist "annotation"))
                 (saved-index
                  (or (and saved-locator
                           (epub-reader-ui--spine-index-for-path
                            publication
                            (epub-reader-locator-path saved-locator)))
                      0))
                 (weights (epub-reader-ui--spine-weights publication))
                 (_session
                  (setq session
                        (epub-reader-session--create
                         :publication publication
                         :dom-cache (make-hash-table :test #'equal)
                         :store store :history-back nil :history-forward nil
                         :bookmarks bookmarks :annotations annotations
                         :spine-weights weights
                         :total-weight
                         (cl-loop for weight across weights sum weight))))
                 (_chapter
                  (epub-reader-ui--load-chapter session saved-index))
                 (target
                  (if saved-locator
                      (epub-reader-ui--restore-target-index
                       session saved-locator)
                    0))
                 (range
                  (epub-reader-ui--chunk-range
                   (epub-reader-ui--current-blocks session) target 'first))
                 (name
                  (generate-new-buffer-name
                   (format "*EPUB: %s*"
                           (epub-reader-publication-title publication)))))
            ;; Create the TextUI buffer first so the session is its buffer-local
            ;; owner before the initial render.  A dynamic `let' of the
            ;; buffer-local variable would only bind the value of whichever
            ;; reader buffer happens to be current when a second book opens.
            (setq buffer (get-buffer-create name))
            (with-current-buffer buffer
              (textui-mode)
              (setq-local epub-reader-ui--session session))
            (textui-open
             name #'epub-reader-ui-frame
             (list :spine-index saved-index :chunk-start (car range)
                   :chunk-end (cadr range)
                   :loading nil :error nil
                   :pending-locator saved-locator
                   :restore-quality nil)))
          (with-current-buffer buffer
            (setq-local epub-reader-ui--session session)
            (epub-reader-ui-mode 1)
            (setq-local buffer-file-name nil)
            (setq-local header-line-format
                        '(:eval (epub-reader-ui--header-line)))
            (setq-local default-directory
                        (file-name-directory (expand-file-name file))))
          (when (epub-reader-session-store session)
            (dolist (warning
                     (delq nil
                           (list
                            (epub-reader-store-warning
                             (epub-reader-session-store session))
                            (epub-reader-store-progress-warning
                             (epub-reader-session-store session)))))
              (message "%s" warning)))
          (textui-register-cleanup
           buffer
           (lambda ()
             (dolist (secondary
                      (and session
                           (list
                            (epub-reader-session-toc-buffer session)
                            (epub-reader-session-bookmark-buffer session)
                            (epub-reader-session-annotation-buffer session))))
               (when (buffer-live-p secondary)
                 (kill-buffer secondary)))
             (unwind-protect
                 (when (epub-reader-session-store session)
                   (condition-case error-data
                       (progn
                         (epub-reader-ui--save-progress)
                         (epub-reader-store-close
                          (epub-reader-session-store session)))
                     (error
                      (message "EPUB final sidecar save failed: %s"
                               (error-message-string error-data)))))
               (epub-reader-publication-close publication))))
          (with-current-buffer buffer
            (if (plist-get textui-state :pending-locator)
                (epub-reader-ui--restore-progress)
              (epub-reader-ui--goto-start))
            (epub-reader-ui--initialize-progress-position)
            (epub-reader-ui--schedule-background-work
             session (plist-get textui-state :spine-index)))
          (setq succeeded t)
          buffer)
      (unless succeeded
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when publication
          (ignore-errors (epub-reader-publication-close publication)))))))

(provide 'epub-reader-ui)
;;; epub-reader-ui.el ends here
