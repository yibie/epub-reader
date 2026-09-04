;;; epub-reader-ui.el --- Single-chapter TextUI EPUB reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (textui "0.7.0"))

;;; Commentary:

;; This is the first vertical reader slice: a centered chapter frame, width
;; reflow delegated to TextUI, internal/external links, and spine navigation.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'face-remap)
(require 'subr-x)
(require 'textui)
(require 'textui-keyed-region)
(require 'textui-widgets)
(require 'epub-reader-annotation)
(require 'epub-reader-annotation-index)
(require 'epub-reader-layout)
(require 'epub-reader-locator)
(require 'epub-reader-note)
(require 'epub-reader-panel)
(require 'epub-reader-publication)
(require 'epub-reader-render)
(require 'epub-reader-store)

(defcustom epub-reader-reading-width 76
  "Preferred width in character cells of the centered reading column."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-line-spacing nil
  "Extra line spacing used for prose lines in reader buffers.
Nil means inherit `line-spacing' from the buffer or selected frame."
  :type '(choice (const :tag "Inherit the global line spacing" nil)
                 number)
  :group 'epub-reader)

(defcustom epub-reader-paragraph-spacing 1
  "Number of blank lines inserted between reading-column blocks."
  :type 'integer
  :group 'epub-reader)

(defconst epub-reader-ui--minimum-chrome-width 10
  "Minimum width at which the reader renders header and footer chrome.
Below this width the chapter remains usable while chrome is omitted.  This
also keeps parent layout padding from extending chapter lines beyond their
refresh-region text properties during transient narrow-window layouts.")

(defcustom epub-reader-text-scale 0
  "Text scale level applied when a reader buffer is opened.
The value has the same meaning as the argument to `text-scale-set'."
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

(defcustom epub-reader-toc-width 34
  "Preferred width in character cells of the table-of-contents panel."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-list-width 42
  "Preferred width in character cells of bookmark and annotation panels."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-reader-min-width 40
  "Minimum reader width preserved when opening a horizontal side panel."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-side-min-width 20
  "Minimum useful width for a horizontal EPUB side panel."
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

(defcustom epub-reader-first-paint-max-blocks 2
  "Maximum semantic blocks rendered synchronously on chapter entry."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-first-paint-max-characters 4000
  "Maximum source characters rendered synchronously on chapter entry."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-scroll-chunk-max-blocks 1
  "Base block allowance for a cold interactive chunk shift.
Half the edge guard may raise this allowance so a completed shift moves the
active block out of the trigger zone without laying out a whole screen of new
paragraphs at once.  The character allowance remains independently bounded by
`epub-reader-scroll-chunk-max-characters'."
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

(defface epub-reader-panel-active-tab-face
  '((t (:inherit mode-line-emphasis :weight bold)))
  "Face for the selected view tab in the EPUB panel."
  :group 'epub-reader)

(defface epub-reader-panel-inactive-tab-face
  '((t (:inherit shadow)))
  "Face for an unselected view tab in the EPUB panel."
  :group 'epub-reader)

(cl-defstruct (epub-reader-session
               (:constructor epub-reader-session--create))
  "Non-UI state owned by one reader buffer."
  publication current-chapter dom-cache store
  refreshing-p producer-block-count history-back history-forward
  panel-buffer panel panel-view bookmarks annotations
  annotation-index
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

(defvar-local epub-reader-ui--layout-group nil
  "Managed window group owned by the current EPUB reader buffer.")

(defvar-local epub-reader-ui--saved-line-spacing nil
  "Saved `(LOCAL-P . VALUE)' for restoring the user's line spacing.")

(defvar-local epub-reader-ui--prose-line-spacing nil
  "Line spacing copied onto non-image rows in the current reader buffer.")

(defvar-local epub-reader-ui--panel-view-reader nil
  "Reader buffer owning the current panel buffer.")

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

(defvar-keymap epub-reader-panel-view-map
  :doc "Keys shared by every view of the EPUB panel."
  "1" #'epub-reader-panel-select-contents
  "2" #'epub-reader-panel-select-highlights
  "3" #'epub-reader-panel-select-bookmarks
  "t" #'epub-reader-panel-select-contents
  "a" #'epub-reader-panel-select-highlights
  "M" #'epub-reader-panel-select-bookmarks)

(defvar-keymap epub-reader-toc-mode-map
  :doc "Keymap active while the EPUB panel shows the table of contents."
  :parent epub-reader-panel-view-map
  "n" #'epub-reader-toc-next-chapter
  "]" #'epub-reader-toc-next-chapter
  "p" #'epub-reader-toc-previous-chapter
  "[" #'epub-reader-toc-previous-chapter
  "RET" #'epub-reader-toc-activate
  "TAB" #'epub-reader-toc-toggle
  "t" #'epub-reader-toc-quit
  "q" #'epub-reader-toc-quit)

(defvar-keymap epub-reader-bookmark-list-mode-map
  :doc "Keymap active while the EPUB panel shows bookmarks."
  :parent epub-reader-panel-view-map
  "RET" #'epub-reader-bookmark-list-activate
  "d" #'epub-reader-bookmark-list-delete
  "M" #'epub-reader-bookmark-list-quit
  "q" #'epub-reader-bookmark-list-quit)

(defvar-keymap epub-reader-annotation-list-mode-map
  :doc "Keymap active while the EPUB panel shows highlights and notes."
  :parent epub-reader-panel-view-map
  "n" #'epub-reader-annotation-list-next
  "p" #'epub-reader-annotation-list-previous
  "RET" #'epub-reader-annotation-list-activate
  "d" #'epub-reader-annotation-list-delete
  "e" #'epub-reader-annotation-list-edit-note
  "a" #'epub-reader-annotation-list-quit
  "q" #'epub-reader-annotation-list-quit)
(defvar epub-reader-ui-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'epub-reader-follow-link)
    (define-key map [mouse-1] #'epub-reader-follow-link-mouse)
    map)
  "Keymap installed by the UI on rendered EPUB hyperlink runs.")

(defvar epub-reader-toc-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'epub-reader-toc-activate-mouse)
    map)
  "Keymap installed on TOC rows so that a click acts like RET.")

(defvar epub-reader-bookmark-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'epub-reader-bookmark-list-activate-mouse)
    map)
  "Keymap installed on bookmark list rows so that a click acts like RET.")

(defvar epub-reader-annotation-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'epub-reader-annotation-list-activate-mouse)
    map)
  "Keymap installed on annotation list rows so that a click acts like RET.")

(defconst epub-reader-ui--panel-views
  '((toc "Contents" epub-reader-toc-frame epub-reader-toc-mode)
    (annotations "Highlights" epub-reader-annotation-list-frame
                 epub-reader-annotation-list-mode)
    (bookmarks "Bookmarks" epub-reader-bookmark-list-frame
               epub-reader-bookmark-list-mode))
  "Panel views as (VIEW LABEL RENDER-FUNCTION MINOR-MODE), in tab order.")

(defun epub-reader-ui--panel-view-entry (view)
  "Return the `epub-reader-ui--panel-views' entry for VIEW."
  (or (assq view epub-reader-ui--panel-views)
      (error "Unknown EPUB panel view: %S" view)))

(defun epub-reader-ui--panel-reader-session ()
  "Return the live reader session owned by the current panel buffer."
  (unless (buffer-live-p epub-reader-ui--panel-view-reader)
    (user-error "The EPUB reader buffer has been closed"))
  (with-current-buffer epub-reader-ui--panel-view-reader
    (epub-reader-ui--current-session)))

(defun epub-reader-ui--panel-view-buffer (session view)
  "Return SESSION's live panel buffer when it currently shows VIEW."
  (let ((buffer (epub-reader-session-panel-buffer session)))
    (and (buffer-live-p buffer)
         (eq (plist-get (buffer-local-value 'textui-state buffer) :view) view)
         buffer)))

(defun epub-reader-ui--select-panel-tab (view)
  "Show VIEW in the panel that owns the current panel buffer."
  (let ((reader epub-reader-ui--panel-view-reader))
    (unless (buffer-live-p reader)
      (user-error "The EPUB reader buffer has been closed"))
    (with-current-buffer reader
      (epub-reader-ui--show-panel-view view))))

(defun epub-reader-panel-select-contents ()
  "Show the table of contents in the EPUB panel."
  (interactive)
  (epub-reader-ui--select-panel-tab 'toc))

(defun epub-reader-panel-select-highlights ()
  "Show highlights and notes in the EPUB panel."
  (interactive)
  (epub-reader-ui--select-panel-tab 'annotations))

(defun epub-reader-panel-select-bookmarks ()
  "Show bookmarks in the EPUB panel."
  (interactive)
  (epub-reader-ui--select-panel-tab 'bookmarks))

(defun epub-reader-ui--panel-tab-label (widget)
  "Return the padded label drawn for tab WIDGET."
  (format " %s " (widget-get widget :tag)))

(defun epub-reader-ui--panel-tab-value-create (widget)
  "Insert the label of tab WIDGET."
  (insert (epub-reader-ui--panel-tab-label widget)))

(defun epub-reader-ui--panel-tab-face (widget)
  "Return the face for tab WIDGET, depending on whether it is active."
  (if (widget-get widget :epub-reader-active)
      'epub-reader-panel-active-tab-face
    'epub-reader-panel-inactive-tab-face))

(defun epub-reader-ui--panel-tab-notify (widget &rest _)
  "Switch the panel to the view carried by tab WIDGET."
  (epub-reader-ui--select-panel-tab (widget-get widget :epub-reader-view)))

(define-widget 'epub-reader-panel-tab 'textui-button
  "One tab of the EPUB panel: Contents, Highlights, or Bookmarks.
Clicking it with the mouse or pressing RET on it switches the panel view."
  :textui-measure #'epub-reader-ui--panel-tab-label
  :value-create #'epub-reader-ui--panel-tab-value-create
  :button-face-get #'epub-reader-ui--panel-tab-face
  :notify #'epub-reader-ui--panel-tab-notify)

(defun epub-reader-ui--panel-tab-element (entry current)
  "Return the tab element for panel view ENTRY; CURRENT is the shown view."
  (list :type 'epub-reader-panel-tab
        :tag (nth 1 entry)
        :epub-reader-view (car entry)
        :epub-reader-active (eq (car entry) current)
        :help-echo (format "mouse-1, RET: show %s" (nth 1 entry))))

(defun epub-reader-panel-frame (available-width)
  "Render the panel: a row of view tabs above the current view's content."
  (let* ((view (plist-get textui-state :view))
         (entry (epub-reader-ui--panel-view-entry view)))
    (list
     (list :type :flex :direction :column :gap 1
           :children
           (cons (list :type :flex :direction :row :gap 0
                       :children
                       (mapcar (lambda (candidate)
                                 (epub-reader-ui--panel-tab-element
                                  candidate view))
                               epub-reader-ui--panel-views))
                 (funcall (nth 2 entry) available-width))))))

(defun epub-reader-ui--apply-panel-view-mode (view)
  "Enable VIEW's minor mode in the current panel buffer, disabling the rest."
  (dolist (entry epub-reader-ui--panel-views)
    (let ((mode (nth 3 entry)))
      (when (and (not (eq (car entry) view)) (symbol-value mode))
        (funcall mode -1))))
  (funcall (nth 3 (epub-reader-ui--panel-view-entry view)) 1))

(defun epub-reader-ui--panel-selected-id (view)
  "Return the id of the VIEW item at point in the current panel buffer."
  (pcase view
    ('bookmarks
     (when-let* ((bookmark (epub-reader-bookmark-list--at-point)))
       (epub-reader-bookmark-id bookmark)))
    ('annotations
     (when-let* ((annotation (epub-reader-annotation-list--at-point)))
       (epub-reader-annotation-id annotation)))))

(defun epub-reader-ui--switch-panel-view (view)
  "Re-render the current panel buffer showing VIEW, keeping its selection."
  (let* ((previous (plist-get textui-state :view))
         (selected-id (and (eq previous view)
                           (epub-reader-ui--panel-selected-id view))))
    (setq textui-state (plist-put (copy-sequence textui-state) :view view))
    (unless (eq previous view)
      (epub-reader-ui--apply-panel-view-mode view))
    (pcase view
      ('toc (epub-reader-toc--refresh))
      ('bookmarks (epub-reader-bookmark-list--refresh selected-id))
      ('annotations (epub-reader-annotation-list--refresh selected-id)))))

(defun epub-reader-ui--place-panel-point (view window position)
  "Put point on a VIEW item in WINDOW, preferring POSITION when it is one."
  (pcase view
    ('toc (epub-reader-toc--restore-selection window))
    (_
     (let* ((property (if (eq view 'bookmarks)
                          'epub-reader-bookmark
                        'epub-reader-annotation))
            (target (if (get-text-property position property)
                        position
                      (epub-reader-ui--first-position-with property))))
       (when target
         (goto-char target)
         (when (window-live-p window)
           (set-window-point window target)))))))

(defun epub-reader-ui--first-position-with (property)
  "Return the first buffer position carrying text PROPERTY, or nil."
  (save-excursion
    (goto-char (point-min))
    (if (get-text-property (point) property)
        (point)
      (next-single-property-change (point) property))))

(defun epub-reader-ui--press-panel-widget ()
  "Press the panel widget at point; return non-nil when there was one."
  (when-let* ((widget (widget-at (point))))
    (widget-apply widget :action)
    t))

(defun epub-reader-ui--show-panel-view (view)
  "Show VIEW in this reader's panel buffer, creating the buffer when needed.
Return the panel buffer."
  (epub-reader-ui--panel-view-entry view)
  (let* ((reader (current-buffer))
         (session (epub-reader-ui--current-session))
         (group (epub-reader-ui--ensure-layout reader))
         (existing (epub-reader-session-panel-buffer session))
         (buffer
          (if (buffer-live-p existing)
              existing
            (let* ((epub-reader-ui--panel-view-reader reader)
                   (created
                    (epub-reader-ui--open-secondary-textui
                     (generate-new-buffer-name
                      (format "*EPUB Panel: %s*"
                              (epub-reader-publication-title
                               (epub-reader-session-publication session))))
                     #'epub-reader-panel-frame
                     (list :view view :collapsed nil :selected-key nil))))
              (with-current-buffer created
                (setq-local epub-reader-ui--panel-view-reader reader)
                (epub-reader-ui--apply-panel-view-mode view))
              (setf (epub-reader-session-panel-buffer session) created)
              created))))
    (when (eq buffer existing)
      (with-current-buffer buffer
        (epub-reader-ui--switch-panel-view view)))
    (let* ((position (with-current-buffer buffer (point)))
           (window (epub-reader-ui--focus-panel-view
                    reader session group buffer view)))
      ;; A new buffer was rendered before it had a window, so render it
      ;; again at the panel's real width instead of waiting for redisplay.
      (unless (eq buffer existing)
        (textui-refresh buffer))
      (with-current-buffer buffer
        (epub-reader-ui--place-panel-point view window position)))
    buffer))

(defun epub-reader-ui--hide-line-end-indicators ()
  "Hide truncation and continuation marks in the current TextUI buffer."
  (setq-local fringe-indicator-alist
              (copy-tree fringe-indicator-alist))
  (dolist (indicator '(truncation continuation))
    (when-let* ((entry (assq indicator fringe-indicator-alist)))
      (setcdr entry '(nil nil))))
  ;; A child frame with zero-width fringes draws these indicators in the
  ;; window's final text column, where the default truncation glyph is `$'.
  (setq-local buffer-display-table
              (copy-sequence (or buffer-display-table
                                 standard-display-table
                                 (make-display-table))))
  (set-display-table-slot buffer-display-table 'truncation ?\s)
  (set-display-table-slot buffer-display-table 'wrap ?\s))

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
                    (or epub-reader-line-spacing
                        line-spacing
                        (frame-parameter (selected-frame) 'line-spacing)))
        (setq-local line-spacing 0)
        (epub-reader-ui--disable-image-line-spacing (current-buffer))
        ;; TextUI already emits physical lines at the requested frame width.
        ;; A second Emacs soft-wrap can expose a lone glyph in the margin.
        (setq-local truncate-lines t)
        ;; Fixed-width TextUI rows need neither Emacs continuation nor
        ;; truncation fringe glyphs; those form a distracting vertical rail
        ;; beside centered CJK prose.
        (epub-reader-ui--hide-line-end-indicators)
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
  (setq-local truncate-lines t)
  (epub-reader-ui--hide-line-end-indicators))

(define-minor-mode epub-reader-bookmark-list-mode
  "Minor mode for the secondary EPUB bookmark list buffer."
  :init-value nil
  :lighter " EPUB-Bookmarks"
  :keymap epub-reader-bookmark-list-mode-map
  (setq-local truncate-lines t)
  (epub-reader-ui--hide-line-end-indicators))

(define-minor-mode epub-reader-annotation-list-mode
  "Minor mode for the secondary EPUB annotation list buffer."
  :init-value nil
  :lighter " EPUB-Annotations"
  :keymap epub-reader-annotation-list-mode-map
  (setq-local truncate-lines t)
  (epub-reader-ui--hide-line-end-indicators))

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

(defun epub-reader-ui--ensure-layout (&optional reader)
  "Return READER's managed layout, registering its visible window."
  (let* ((reader (or reader (current-buffer)))
         (window
          (or (and (eq (window-buffer (selected-window)) reader)
                   (selected-window))
              (get-buffer-window reader (selected-frame))
              (get-buffer-window reader t))))
    (unless (window-live-p window)
      (user-error "The EPUB reader is not displayed"))
    (with-current-buffer reader
      (unless (and (epub-reader-layout-live-p epub-reader-ui--layout-group)
                   (eq (epub-reader-layout-group-frame
                        epub-reader-ui--layout-group)
                       (window-frame window)))
        (when (epub-reader-layout-live-p epub-reader-ui--layout-group)
          (epub-reader-layout-release epub-reader-ui--layout-group))
        (setq-local epub-reader-ui--layout-group
                    (epub-reader-layout-create reader (window-frame window))))
      (epub-reader-layout-manage-window
       epub-reader-ui--layout-group window reader 'reader)
      epub-reader-ui--layout-group)))

(defun epub-reader-ui--safe-reader-display-window (_buffer _alist)
  "Return or create a non-side, unmanaged window for restoring a reader."
  (or (cl-find-if
       (lambda (window)
         (and (not (eq window (selected-window)))
              (not (window-dedicated-p window))
              (not (window-parameter window 'window-side))
              (not (epub-reader-layout-managed-window-p window))))
       (window-list (selected-frame) 'no-minibuffer))
      (split-window-sensibly (selected-window))
      (condition-case nil
          (split-window (window-main-window (selected-frame)) nil 'below)
        (error nil))
      (user-error "No safe window is available for the EPUB reader")))

(defun epub-reader-ui--session-panel-origin-window (session)
  "Return the live reader window retained by SESSION's panel."
  (epub-reader-panel-origin-window (epub-reader-session-panel session)))

(defun epub-reader-ui--select-reader-window (reader)
  "Select READER on its owning frame and restore its managed layout."
  (unless (buffer-live-p reader)
    (user-error "The EPUB reader buffer has been closed"))
  (save-current-buffer
    (let* ((associated-window (selected-window))
           (associated-buffer (window-buffer associated-window))
           (associated-role
            (with-current-buffer associated-buffer
              (cond ((bound-and-true-p epub-reader-toc-mode) 'panel)
                    ((bound-and-true-p epub-reader-bookmark-list-mode) 'panel)
                    ((bound-and-true-p epub-reader-annotation-list-mode)
                     'panel))))
           (reader-window
            (or (with-current-buffer reader
                  (and epub-reader-ui--session
                       (epub-reader-ui--session-panel-origin-window
                        epub-reader-ui--session)))
                (get-buffer-window reader (selected-frame))
                (get-buffer-window reader t)
                (display-buffer
                 reader
                 '((display-buffer-use-some-window)
                   (some-window . epub-reader-ui--safe-reader-display-window)
                   (inhibit-same-window . t))))))
      (unless (window-live-p reader-window)
        (user-error "The EPUB reader could not be displayed"))
      (select-window reader-window)
      (let ((group (epub-reader-ui--ensure-layout reader)))
        (when (and associated-role
                   (window-live-p associated-window)
                   (eq (window-frame associated-window)
                       (window-frame reader-window))
                   (eq (window-buffer associated-window) associated-buffer))
          (let ((existing
                 (epub-reader-layout-window group associated-role)))
            (unless (and (window-live-p existing)
                         (not (eq existing associated-window)))
              (epub-reader-layout-manage-window
               group associated-window associated-buffer associated-role)))))
      reader-window)))

(defun epub-reader-ui--open-secondary-textui (name render-function state)
  "Create and render a secondary TextUI buffer without changing user layout."
  (epub-reader-layout-with-inhibited
    (save-window-excursion
      (textui-open name render-function state))))

(defun epub-reader-ui--close-layout-role (reader role)
  "Close READER's managed ROLE window and focus the reader when visible."
  (when (buffer-live-p reader)
    (let* ((group
            (with-current-buffer reader epub-reader-ui--layout-group))
           (role-window
            (and (epub-reader-layout-live-p group)
                 (epub-reader-layout-window group role)))
           (selected (selected-window)))
      (if (window-live-p role-window)
          (epub-reader-layout-close-role group role)
        (when (eq (window-buffer selected) (current-buffer))
          (quit-restore-window selected)))
      (let ((reader-window
             (or (get-buffer-window reader (selected-frame))
                 (get-buffer-window reader t))))
        (when (window-live-p reader-window)
          (select-window reader-window))))))

(defun epub-reader-ui--refit-panel-view (session view)
  "Refit SESSION's visible panel when it is currently showing VIEW."
  (let ((panel (epub-reader-session-panel session)))
    (when (and (eq (epub-reader-session-panel-view session) view)
               (epub-reader-panel-visible-p panel))
      (epub-reader-panel-refit panel))))

(defun epub-reader-ui--hide-session-panel (reader)
  "Hide READER's reusable panel and restore focus to the reader."
  (when (buffer-live-p reader)
    (let* ((session
            (with-current-buffer reader
              (epub-reader-ui--current-session)))
           (panel (epub-reader-session-panel session)))
      (unless (epub-reader-panel-hide panel)
        (setf (epub-reader-session-panel session) nil
              (epub-reader-session-panel-view session) nil)
        (epub-reader-ui--close-layout-role reader 'panel)))))

(defun epub-reader-ui--display-panel-buffer
    (group buffer placement _reader-window)
  "Display BUFFER for GROUP through the ordinary panel layout adapter."
  (if (eq placement 'bottom)
      (epub-reader-layout-display-side-buffer
       group buffer 'panel 'bottom 0 epub-reader-panel-height 0 0)
    (epub-reader-layout-display-side-buffer
     group buffer 'panel 'right 0
     (max epub-reader-toc-width epub-reader-list-width)
     epub-reader-reader-min-width epub-reader-side-min-width)))

(defun epub-reader-ui--focus-panel-view
    (reader session group buffer view)
  "Show BUFFER as SESSION's VIEW in its single reusable panel host."
  (let ((panel (epub-reader-session-panel session)))
    (setf (epub-reader-session-panel-view session) view)
    (if (epub-reader-panel-live-p panel)
        (progn
          (epub-reader-panel-set-buffer panel buffer)
          (epub-reader-panel-focus panel))
      (let ((reader-window (get-buffer-window reader t)))
        (unless (window-live-p reader-window)
          (user-error "The EPUB reader is not displayed"))
        (setq panel
              (let ((epub-reader-panel-width
                     (max epub-reader-toc-width epub-reader-list-width)))
                (epub-reader-panel-open
                 buffer reader-window
                 (lambda (panel-buffer placement origin)
                   (epub-reader-ui--display-panel-buffer
                    group panel-buffer placement origin))
                 (lambda (_panel-window)
                   (epub-reader-layout-close-role group 'panel))
                 'right)))
        (setf (epub-reader-session-panel session) panel)
        (epub-reader-panel-focus panel)))))

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

(defun epub-reader-ui--chunk-start
    (blocks end &optional max-blocks max-characters)
  "Return inclusive chunk start in BLOCKS before END under both budgets."
  (let ((start end)
        (characters 0)
        (block-limit (or max-blocks epub-reader-chunk-max-blocks))
        (character-limit
         (or max-characters epub-reader-chunk-max-characters)))
    (while (and (> start 0)
                (< (- end start) block-limit)
                (or (= start end)
                    (<= (+ characters
                           (length
                            (epub-reader-block-text
                             (aref blocks (1- start)))))
                        character-limit)))
      (setq start (1- start)
            characters
            (+ characters
               (length (epub-reader-block-text (aref blocks start))))))
    start))

(defun epub-reader-ui--chunk-range
    (blocks target-index &optional small-budget current-range direction)
  "Return a budgeted range containing TARGET-INDEX.
SMALL-BUDGET may be `first' for chapter entry, `restore' for restored
progress, or `scroll' for a cold shift.  With CURRENT-RANGE and DIRECTION, a
scroll range adds coverage beyond that edge and retains overlapping context."
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
                  (if (eq small-budget 'restore)
                      0
                    (if small-budget
                        (/ (max 1 max-blocks) 2)
                      (epub-reader-ui--overscan-blocks))))))
         (end (epub-reader-ui--chunk-end
               blocks start max-blocks max-characters)))
    (cond
     ((and (eq small-budget 'scroll) current-range direction)
      (let ((addition-blocks
             (max max-blocks
                  (max 1 (/ (1+ epub-reader-chunk-guard-blocks) 2)))))
        (pcase direction
          ('forward
           (let* ((current-start (car current-range))
                  (current-end (cadr current-range))
                  (next-end
                   (epub-reader-ui--chunk-end
                    blocks current-end addition-blocks max-characters)))
             (if (= next-end current-end)
                 (setq start current-start end current-end)
               (setq start
                     (min target
                          (epub-reader-ui--chunk-start blocks next-end))
                     end next-end))))
          ('backward
           (let* ((current-start (car current-range))
                  (current-end (cadr current-range))
                  (next-start
                   (epub-reader-ui--chunk-start
                    blocks current-start addition-blocks max-characters)))
             (if (= next-start current-start)
                 (setq start current-start end current-end)
               (setq start next-start
                     end
                     (max (1+ target)
                          (epub-reader-ui--chunk-end
                           blocks next-start)))))))))
     ((>= target end)
      (setq start target
            end (epub-reader-ui--chunk-end
                 blocks start max-blocks max-characters))))
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

(defun epub-reader-ui--queue-expand-job (session index)
  "Queue one idle full-budget expansion for SESSION chapter INDEX."
  (unless (cl-some
           (lambda (job)
             (and (eq (car job) 'expand) (= (cadr job) index)))
           (epub-reader-session-background-jobs session))
    (setf (epub-reader-session-background-jobs session)
          (append (epub-reader-session-background-jobs session)
                  (list (list 'expand index)))))
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
        (textui-reconcile-keyed-region
         (current-buffer) 'chapter #'epub-reader-ui--chapter-keyed-entries)
        (epub-reader-ui--post-render (current-buffer))))))

(defun epub-reader-ui--background-expand-job (session index)
  "Expand SESSION's first-paint chunk for spine INDEX to its full budget."
  (when (= index (epub-reader-ui--state-value :spine-index))
    (let* ((blocks (epub-reader-ui--current-blocks session))
           (locator
            (epub-reader-ui--locator-at-reading-row index (point)))
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

(defun epub-reader-ui--heading-label (blocks)
  "Return the trimmed text of the first heading in BLOCKS, or nil."
  (cl-loop for block across blocks
           when (eq (epub-reader-block-kind block) 'heading)
           return (let ((text (string-trim
                               (substring-no-properties
                                (epub-reader-block-text block)))))
                    (and (not (string-empty-p text)) text))))

(defun epub-reader-ui--toc-label-for-spine-index (publication index)
  "Return the first PUBLICATION TOC label whose target is spine INDEX."
  (let* ((resource (epub-reader-publication-spine-resource publication index))
         (path (and resource (epub-reader-resource-path resource))))
    (when path
      (cl-labels ((search (entries)
                    (catch 'found
                      (dolist (entry entries)
                        (let ((label (string-trim
                                      (epub-reader-toc-entry-label entry))))
                          (when (and (equal (epub-reader-toc-entry-path entry)
                                            path)
                                     (not (string-empty-p label)))
                            (throw 'found label)))
                        (let ((nested (search
                                       (epub-reader-toc-entry-children entry))))
                          (when nested (throw 'found nested))))
                      nil)))
        (search (epub-reader-publication-toc publication))))))

(defun epub-reader-ui--cjk-numeral (number)
  "Return NUMBER as a Chinese numeral below 100, otherwise as decimal digits."
  (let ((digits ["零" "一" "二" "三" "四" "五" "六" "七" "八" "九"]))
    (cond ((or (< number 1) (>= number 100)) (number-to-string number))
          ((< number 10) (aref digits number))
          (t (let ((tens (/ number 10))
                   (ones (% number 10)))
               (concat (if (> tens 1) (aref digits tens) "")
                       "十"
                       (if (> ones 0) (aref digits ones) "")))))))

(defun epub-reader-ui--numbered-chapter-label (language number)
  "Return a numbered fallback label for chapter NUMBER written in LANGUAGE."
  (let ((language (downcase (or language ""))))
    (cond ((or (string-prefix-p "zh" language)
               (string-prefix-p "ja" language))
           (format "第%s章" (epub-reader-ui--cjk-numeral number)))
          ((string-prefix-p "ko" language)
           (format "제%d장" number))
          (t (format "Chapter %d" number)))))

(defun epub-reader-ui--chapter-label (session index)
  "Return a readable label for SESSION spine INDEX.
Prefer the chapter's own first heading, then its table-of-contents label,
and finally a chapter number in the publication's language."
  (let ((publication (epub-reader-session-publication session)))
    (or (epub-reader-ui--heading-label
         (epub-reader-chapter-data-blocks
          (epub-reader-ui--chapter-data session index)))
        (epub-reader-ui--toc-label-for-spine-index publication index)
        (epub-reader-ui--numbered-chapter-label
         (epub-reader-publication-language publication) (1+ index)))))

(defun epub-reader-ui--chapter-title ()
  "Return a readable title for the current chapter."
  (epub-reader-ui--chapter-label (epub-reader-ui--current-session)
                                 (epub-reader-ui--state-value :spine-index)))

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
  "Resolve pending progress into a useful bounded chunk and report quality."
  (let ((locator (plist-get textui-state :pending-locator)))
    (when locator
      (let* ((session (epub-reader-ui--current-session))
             (blocks (epub-reader-ui--current-blocks session))
             (target (epub-reader-ui--restore-target-index session locator))
             (_visible (epub-reader-ui--ensure-block-visible target))
             (initial-resolution (epub-reader-locator-goto locator))
             (position
              (epub-reader-locator-resolution-position initial-resolution))
             (source
              (and position
                   (get-text-property position 'epub-reader-source)))
             (resolved-target
              (or (and (epub-reader-locator-source-p source)
                       (gethash (aref source 1)
                                (epub-reader-ui--current-block-index session)))
                  target))
             (range
              (epub-reader-ui--chunk-range
               blocks resolved-target 'restore))
             (_restored-chunk
              (unless (and (= (car range)
                              (plist-get textui-state :chunk-start))
                           (= (cadr range)
                              (plist-get textui-state :chunk-end)))
                (epub-reader-ui--refresh-chunk
                 (car range) (cadr range))))
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
  (let ((blocks (epub-reader-chapter-data-blocks chapter)))
    (if (= (length blocks) 0)
        (make-hash-table :test #'equal)
      (let ((spine-index
             (epub-reader-block-spine-index (aref blocks 0))))
        (epub-reader-annotation-index-chapter-spans
         (epub-reader-session-annotation-index session)
         spine-index spine-index
         (epub-reader-chapter-data-locator-index chapter))))))

(defun epub-reader-ui--chapter-keyed-entries (available-width)
  "Return keyed current-chapter block elements at AVAILABLE-WIDTH."
  (let* ((session (epub-reader-ui--current-session))
         (chapter (epub-reader-ui--current-chapter session))
         (blocks (epub-reader-chapter-data-blocks chapter))
         (start (or (plist-get textui-state :chunk-start) 0))
         (end (or (plist-get textui-state :chunk-end) (length blocks)))
         (image-rows (epub-reader-ui--image-row-budget))
         (highlights (epub-reader-ui--annotation-spans-by-block
                      session chapter))
         entries)
    (cl-loop for index from start below (min end (length blocks))
             for block = (aref blocks index)
             for element = (epub-reader-render-block-element
                            block
                            (epub-reader-session-publication session)
                            (epub-reader-chapter-data-section chapter)
                            image-rows t
                            (gethash (epub-reader-block-key block) highlights)
                            (list
                             (epub-reader-block-document-path block)
                             (epub-reader-block-key block)
                             (gethash (epub-reader-block-key block)
                                      highlights)))
             do (push
                 (list (epub-reader-block-key block)
                       (epub-reader-ui--centered-column
                        available-width (list element)))
                 entries))
    (setf (epub-reader-session-producer-block-count session)
          (length entries))
    (nreverse entries)))

(defun epub-reader-ui--chapter-elements (available-width)
  "Return current budgeted chapter children at AVAILABLE-WIDTH."
  (mapcar #'cadr
          (epub-reader-ui--chapter-keyed-entries available-width)))

(defun epub-reader-ui--chapter-region (available-width)
  "Return the refreshable chapter container for AVAILABLE-WIDTH."
  (list :type :flex :direction :column
        :layout '(:refresh-id chapter)
        :gap (max 0 epub-reader-paragraph-spacing)
        :children (epub-reader-ui--chapter-elements available-width)))

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
          (while (and (not (eobp))
                      (<= (line-beginning-position) last-source))
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
    (let ((chapter (epub-reader-ui--chapter-region available-width)))
      (if (< available-width epub-reader-ui--minimum-chrome-width)
          (list chapter)
        (list
         (list
          :type :flex :direction :column :gap 1
          :children
          (list
           (epub-reader-ui--centered-column
            available-width (list (epub-reader-ui--header publication index)))
           chapter
           (epub-reader-ui--centered-column
            available-width (list (epub-reader-ui--footer))))))))))

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

(defun epub-reader-ui--locator-at-reading-row (index position)
  "Return the locator at POSITION or on its centered source row for INDEX."
  (cl-labels
      ((valid-source-position-p
        (cursor)
        (let* ((source (get-text-property cursor 'epub-reader-source))
               (block-index
                (and (epub-reader-locator-source-p source)
                     (gethash
                      (aref source 1)
                      (epub-reader-ui--current-block-index))))
               (block
                (and block-index
                     (aref (epub-reader-ui--current-blocks) block-index))))
          (and block
               (< (aref source 2)
                  (length (epub-reader-block-text block)))))))
    (let ((found (and (valid-source-position-p position) position)))
      (unless found
        (save-excursion
          (goto-char position)
          (let ((ranges
                 (list (cons (line-beginning-position) (line-end-position))
                       (save-excursion
                         (forward-line 1)
                         (cons (line-beginning-position) (line-end-position)))
                       (save-excursion
                         (forward-line -1)
                         (cons (line-beginning-position) (line-end-position))))))
            (while (and ranges (not found))
              (let ((cursor (caar ranges))
                    (end (cdar ranges)))
                (while (and (< cursor end) (not found))
                  (when (valid-source-position-p cursor)
                    (setq found cursor))
                  (setq cursor (1+ cursor))))
              (setq ranges (cdr ranges))))))
      (and found
           (epub-reader-locator-at-point
            index found (current-buffer))))))

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
            :point-locator (epub-reader-ui--locator-at-reading-row
                            index window-point)
            :top-locator (epub-reader-ui--locator-at-reading-row
                          index (window-start window))
            :visual-row (count-screen-lines
                         (window-start window) window-point nil window))
           viewports))))
    (epub-reader-view-state--create
     :point-locator (epub-reader-ui--locator-at-reading-row index (point))
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

(defun epub-reader-ui--refresh-chunk (start end &optional expand)
  "Synchronously replace the chapter region with block range START to END.
Reader locators preserve point and visual rows while keyed TextUI
reconciliation retains the overlapping source blocks.
When EXPAND is non-nil, queue a later full-budget expansion around point."
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
            (textui-reconcile-keyed-region
             buffer 'chapter #'epub-reader-ui--chapter-keyed-entries)
            (epub-reader-ui--post-render buffer)
            (when expand
              (epub-reader-ui--queue-expand-job
               session (epub-reader-ui--state-value :spine-index)))
            (epub-reader-ui--queue-image-job
             session (epub-reader-ui--state-value :spine-index) start end)
            (when view-state
              (epub-reader-ui--restore-view-state view-state))
            (force-mode-line-update t))
        (setf (epub-reader-session-refreshing-p session) nil)))
    buffer))

(defun epub-reader-ui--ensure-block-visible (block-index)
  "Refresh the current chunk if needed to include BLOCK-INDEX."
  (let* ((blocks
          (epub-reader-ui--current-blocks))
         (start (plist-get textui-state :chunk-start))
         (end (plist-get textui-state :chunk-end)))
    (unless (and (<= start block-index) (< block-index end))
      (let* ((direction (if (< block-index start) 'backward 'forward))
             (range
              (epub-reader-ui--chunk-range
               blocks block-index 'scroll (list start end) direction)))
        ;; Semantic jumps may be far beyond the adjacent scroll addition.
        ;; Give those targets a useful bounded first paint of their own.
        (unless (and (<= (car range) block-index)
                     (< block-index (cadr range)))
          (setq range
                (epub-reader-ui--chunk-range blocks block-index 'restore)))
        (epub-reader-ui--refresh-chunk (car range) (cadr range) t)))))

(defun epub-reader-ui--inside-chunk-guard-p
    (block-index start end block-count)
  "Return non-nil when BLOCK-INDEX is in either inclusive chunk guard."
  (or (and (> start 0)
           (<= (- block-index start) epub-reader-chunk-guard-blocks))
      (and (< end block-count)
           (<= (- end block-index) epub-reader-chunk-guard-blocks))))

(defun epub-reader-ui--source-near-viewport-edge (direction)
  "Return source nearest the selected viewport edge in DIRECTION."
  (let ((window (selected-window)))
    (when (eq (window-buffer window) (current-buffer))
      (pcase direction
        ('forward
         (let ((position
                (save-excursion
                  (goto-char (window-start window))
                  (vertical-motion (1- (window-body-height window)) window)
                  (line-end-position)))
               source)
           (while (and (> position (point-min)) (not source))
             (setq position (1- position)
                   source (get-text-property position 'epub-reader-source)))
           (and (epub-reader-locator-source-p source) source)))
        ('backward
         (let ((position (window-start window)) source)
           (while (and (< position (point-max)) (not source))
             (setq source (get-text-property position 'epub-reader-source)
                   position (1+ position)))
           (and (epub-reader-locator-source-p source) source)))))))

(defun epub-reader-ui--maybe-shift-chunk (&optional direction)
  "Shift the chapter window when point approaches a rendered chunk edge."
  (when (and epub-reader-ui-mode
             (epub-reader-session-p epub-reader-ui--session)
             (not (epub-reader-session-refreshing-p epub-reader-ui--session)))
    (let* ((source
            (or (and direction
                     (epub-reader-ui--source-near-viewport-edge direction))
                (epub-reader-locator-source-at-point)))
           (block-index
            (and source
                 (gethash
                  (aref source 1)
                  (epub-reader-ui--current-block-index))))
           (start (plist-get textui-state :chunk-start))
           (end (plist-get textui-state :chunk-end))
           (length (length
                    (epub-reader-ui--current-blocks)))
           (left-guard
            (and block-index (> start 0)
                 (<= (- block-index start)
                     epub-reader-chunk-guard-blocks)))
           (right-guard
            (and block-index (< end length)
                 (<= (- end block-index)
                     epub-reader-chunk-guard-blocks)))
           (direction
            (or direction
                (cond
                 ((and left-guard right-guard)
                  (if (< (- block-index start)
                         (- (1- end) block-index))
                      'backward
                    'forward))
                 (left-guard 'backward)
                 (right-guard 'forward)))))
      (when (and block-index
                 direction
                 (if (eq direction 'backward)
                     left-guard
                   right-guard))
        (pcase-let ((`(,next-start ,next-end)
                     (epub-reader-ui--chunk-range
                      (epub-reader-ui--current-blocks)
                      block-index 'scroll (list start end) direction)))
          ;; Never discard context unless the chosen edge gains new source.
          (when (if (eq direction 'backward)
                    (< next-start start)
                  (> next-end end))
            (epub-reader-ui--refresh-chunk
             next-start next-end
             (< (- end start) epub-reader-chunk-max-blocks))))))))

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
  "Refresh the panel while it shows the TOC, preserving its selected row."
  (when-let* ((buffer (epub-reader-ui--panel-view-buffer
                       (epub-reader-ui--current-session) 'toc)))
    (with-current-buffer buffer
      (epub-reader-toc--refresh))))

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
  ;; Add the next overscan before `scroll-up-command' reaches the temporary
  ;; chunk footer; point can be on chrome rather than source after that error.
  (epub-reader-ui--maybe-shift-chunk 'forward)
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
  (epub-reader-ui--maybe-shift-chunk 'forward))

(defun epub-reader-scroll-backward ()
  "Scroll backward, shifting chunks or moving to the previous chapter end."
  (interactive)
  (epub-reader-ui--maybe-shift-chunk 'backward)
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
  (epub-reader-ui--maybe-shift-chunk 'backward))

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
  (epub-reader-ui--select-reader-window (current-buffer))
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
  "Return one TextUI row element for TOC ROW.
The markers and indentation sit in a fixed leading cell and the label in a
growing cell, so a label wrapped over several lines keeps every continuation
line aligned under its first character instead of at the window edge."
  (let* ((entry (epub-reader-toc-row-entry row))
         (children (epub-reader-toc-entry-children entry))
         (disclosure (cond ((not children) "  ")
                           ((epub-reader-toc-row-expanded-p row) "▾ ")
                           (t "▸ ")))
         (current (if (epub-reader-toc-row-current-p row) "▶ " "  "))
         (properties
          (list 'epub-reader-toc-row row
                'epub-reader-toc-key (epub-reader-toc-row-key row)
                'face (cond ((epub-reader-toc-row-current-p row)
                             'epub-reader-toc-current-face)
                            ((and children
                                  (not (epub-reader-toc-entry-path entry)))
                             'epub-reader-toc-group-face)
                            (t 'default))
                'mouse-face 'highlight
                'keymap epub-reader-toc-row-map
                'help-echo (if (epub-reader-toc-entry-path entry)
                               "RET or mouse-1: jump; TAB: fold"
                             "RET, mouse-1, or TAB: fold")))
         (prefix
          (apply #'propertize
                 (format "%s%s%s" current
                         (make-string (* 2 (epub-reader-toc-row-depth row))
                                      ?\s)
                         disclosure)
                 properties))
         (label
          (apply #'propertize (epub-reader-toc-entry-label entry)
                 properties)))
    (list :type :flex :direction :row :gap 0
          :children
          (list (list :type :text :value prefix)
                (list :type :text :value label :wrap 'greedy
                      :layout '(:min-width 8 :grow 1))))))

(defun epub-reader-toc-frame (_available-width)
  "Return the secondary TextUI table-of-contents frame."
  (let* ((session (epub-reader-ui--panel-reader-session))
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
  "Return the TOC row at point, before point, or owning the current line.
The continuation lines of a wrapped label start with blank padding that
carries no properties, so the row is also looked up at the line's end."
  (or (get-text-property (point) 'epub-reader-toc-row)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'epub-reader-toc-row))
      (save-excursion
        (end-of-line)
        (skip-chars-backward " \t")
        (and (> (point) (line-beginning-position))
             (get-text-property (1- (point)) 'epub-reader-toc-row)))))

(defun epub-reader-toc--key-position (key)
  "Return buffer position of visible TOC row KEY."
  (cl-loop for position from (point-min) below (point-max)
           when (equal (get-text-property position 'epub-reader-toc-key) key)
           return position))

(defun epub-reader-toc--current-key ()
  "Return the first full-hierarchy TOC key for the current chapter."
  (let* ((session (epub-reader-ui--panel-reader-session))
         (publication (epub-reader-session-publication session))
         (current-path (epub-reader-section-path
                        (epub-reader-ui--current-section session))))
    (cl-loop for row in (epub-reader-toc--rows
                         (epub-reader-publication-toc publication)
                         nil current-path)
             when (epub-reader-toc-row-current-p row)
             return (epub-reader-toc-row-key row))))

(defun epub-reader-toc--current-position ()
  "Return buffer position of the visible current-chapter row."
  (cl-loop for position from (point-min) below (point-max)
           for row = (get-text-property position 'epub-reader-toc-row)
           when (and row (epub-reader-toc-row-current-p row))
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
    (when (buffer-live-p epub-reader-ui--panel-view-reader)
      (with-current-buffer epub-reader-ui--panel-view-reader
        (epub-reader-ui--refit-panel-view
         (epub-reader-ui--current-session) 'toc)))
    (epub-reader-toc--restore-selection
     (get-buffer-window (current-buffer) t))))

(defun epub-reader-toc--select-current (window)
  "Reveal and select the current chapter row, updating WINDOW point.
Return nil without changing selection or folding when the spine item has no
TOC entry."
  (when-let* ((key (epub-reader-toc--current-key)))
    (let* ((collapsed (plist-get textui-state :collapsed))
           (revealed
            (cl-remove-if
             (lambda (candidate)
               (string-prefix-p (concat candidate "/") key))
             collapsed)))
      (setq textui-state
            (plist-put
             (plist-put (copy-sequence textui-state)
                        :collapsed revealed)
             :selected-key key))
      (unless (equal collapsed revealed)
        (textui-refresh (current-buffer))
        (when (buffer-live-p epub-reader-ui--panel-view-reader)
          (with-current-buffer epub-reader-ui--panel-view-reader
            (epub-reader-ui--refit-panel-view
             (epub-reader-ui--current-session) 'toc))))
      (epub-reader-toc--restore-selection window))))

(defun epub-reader-toc-quit ()
  "Hide the TOC after saving its selected stable row key."
  (interactive)
  (let ((row (epub-reader-toc--row-at-point)))
    (when row
      (setq textui-state
            (plist-put (copy-sequence textui-state) :selected-key
                       (epub-reader-toc-row-key row)))))
  (let ((reader epub-reader-ui--panel-view-reader))
    (if (buffer-live-p reader)
        (epub-reader-ui--hide-session-panel reader)
      (quit-restore-window (selected-window)))))

(defun epub-reader-toc-toggle ()
  "Toggle the TOC subtree at point, or move past a panel tab."
  (interactive)
  (let* ((row (epub-reader-toc--row-at-point))
         (entry (and row (epub-reader-toc-row-entry row))))
    (cond
     ((widget-at (point)) (widget-forward 1))
     ((not (and row (epub-reader-toc-entry-children entry)))
      (user-error "TOC entry has no children"))
     (t
      (let* ((key (epub-reader-toc-row-key row))
             (collapsed (copy-sequence (plist-get textui-state :collapsed))))
        (setq textui-state
              (plist-put
               (copy-sequence textui-state) :collapsed
               (if (member key collapsed)
                   (delete key collapsed)
                 (cons key collapsed))))
        (epub-reader-toc--refresh))))))

(defun epub-reader-toc--navigate-chapter (command)
  "Run reader chapter COMMAND and select the newly current TOC row."
  (let* ((toc-buffer (current-buffer))
         (toc-window
          (or (and (eq (window-buffer (selected-window)) toc-buffer)
                   (selected-window))
              (get-buffer-window toc-buffer t)))
         (reader epub-reader-ui--panel-view-reader))
    (unless (buffer-live-p reader)
      (user-error "The EPUB reader buffer has been closed"))
    (unwind-protect
        (progn
          (epub-reader-ui--select-reader-window reader)
          (with-current-buffer reader
            (funcall command))
          (epub-reader-toc--select-current toc-window))
      (when (and (window-live-p toc-window)
                 (eq (window-buffer toc-window) toc-buffer))
        (select-window toc-window)))))

(defun epub-reader-toc-next-chapter ()
  "Move the reader to its next chapter and track it in the TOC."
  (interactive)
  (epub-reader-toc--navigate-chapter #'epub-reader-next-chapter))

(defun epub-reader-toc-previous-chapter ()
  "Move the reader to its previous chapter and track it in the TOC."
  (interactive)
  (epub-reader-toc--navigate-chapter #'epub-reader-previous-chapter))

(defun epub-reader-toc-activate ()
  "Press the panel tab at point, jump to the TOC target, or fold a group."
  (interactive)
  (unless (epub-reader-ui--press-panel-widget)
    (let* ((row (epub-reader-toc--row-at-point))
           (entry (and row (epub-reader-toc-row-entry row))))
      (unless row (user-error "No TOC entry at point"))
      (if (not (epub-reader-toc-entry-path entry))
          (epub-reader-toc-toggle)
        (with-current-buffer epub-reader-ui--panel-view-reader
          (epub-reader-ui--jump-to-target
           (epub-reader-toc-entry-path entry)
           (epub-reader-toc-entry-fragment entry)))))))

(defun epub-reader-toc-activate-mouse (event)
  "Move to mouse EVENT and activate the TOC row there."
  (interactive "e")
  (mouse-set-point event)
  (epub-reader-toc-activate))

(defun epub-reader-toc ()
  "Open and focus this reader's hierarchical table of contents."
  (interactive)
  (epub-reader-ui--show-panel-view 'toc))
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

(defun epub-reader-bookmark-list-frame (_available-width)
  "Return the TextUI frame for the current book's bookmarks."
  (let* ((session (epub-reader-ui--panel-reader-session))
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
                   'keymap epub-reader-bookmark-row-map
                   'help-echo "RET or mouse-1: jump; d: delete")))
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
  "Refresh SESSION's panel when it shows bookmarks, keeping SELECTED-ID."
  (when-let* ((buffer (epub-reader-ui--panel-view-buffer session 'bookmarks)))
    (with-current-buffer buffer
      (epub-reader-bookmark-list--refresh selected-id))))

(defun epub-reader-bookmark-list-activate ()
  "Press the panel tab at point, or jump to the bookmark at point."
  (interactive)
  (unless (epub-reader-ui--press-panel-widget)
    (let ((bookmark (epub-reader-bookmark-list--at-point))
          (reader epub-reader-ui--panel-view-reader))
      (unless bookmark (user-error "No bookmark at point"))
      (with-current-buffer reader
        (epub-reader-ui--record-history)
        (epub-reader-ui--goto-locator (epub-reader-bookmark-locator bookmark)))
      (epub-reader-ui--select-reader-window reader))))

(defun epub-reader-bookmark-list-activate-mouse (event)
  "Move to mouse EVENT and jump to the bookmark there."
  (interactive "e")
  (mouse-set-point event)
  (epub-reader-bookmark-list-activate))

(defun epub-reader-bookmark-list-delete ()
  "Delete the bookmark at point from the sidecar."
  (interactive)
  (let* ((bookmark (epub-reader-bookmark-list--at-point))
         (session (epub-reader-ui--panel-reader-session)))
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
  (let ((reader epub-reader-ui--panel-view-reader))
    (if (buffer-live-p reader)
        (epub-reader-ui--hide-session-panel reader)
      (quit-restore-window (selected-window)))))

(defun epub-reader-bookmarks ()
  "Open and focus this book's bookmarks in the panel."
  (interactive)
  (epub-reader-ui--show-panel-view 'bookmarks))

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
    (epub-reader-annotation-index-put
     (epub-reader-session-annotation-index session) annotation)
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
  (epub-reader-annotation-index-put
   (epub-reader-session-annotation-index session) annotation)
  (epub-reader-store-stage-annotation
   (epub-reader-session-store session)
   (epub-reader-annotation-to-plist annotation))
  (epub-reader-ui--flush-reader-marks session)
  annotation)

(defun epub-reader-ui--edit-annotation-note (reader annotation)
  "Open a note editor for ANNOTATION owned by READER."
  (let ((annotation-id (epub-reader-annotation-id annotation)))
    (epub-reader-note-edit
     (epub-reader-annotation-note annotation)
     (lambda (note)
       (unless (buffer-live-p reader)
         (user-error "The EPUB reader buffer has been closed"))
       (with-current-buffer reader
         (let* ((session (epub-reader-ui--current-session))
                (live-annotation
                 (epub-reader-ui--annotation-by-id session annotation-id)))
           (unless live-annotation
             (user-error "This EPUB highlight no longer exists"))
           (epub-reader-ui--set-annotation-note
            session live-annotation note)
           (epub-reader-ui--refresh-chunk
            (plist-get textui-state :chunk-start)
            (plist-get textui-state :chunk-end))
           (epub-reader-ui--refresh-live-annotation-list
            session annotation-id)
           (message "Highlight note saved"))))
     reader
     (or (with-current-buffer reader
           (and epub-reader-ui--session
                (epub-reader-ui--session-panel-origin-window
                 epub-reader-ui--session)))
         (get-buffer-window reader t))
     annotation-id)))

(defun epub-reader-edit-note ()
  "View or edit the note attached to the highlight at point."
  (interactive)
  (let* ((session (epub-reader-ui--current-session))
         (annotation (epub-reader-ui--annotation-at-point session)))
    (unless annotation (user-error "Point is not on an EPUB highlight"))
    (epub-reader-ui--edit-annotation-note (current-buffer) annotation)))

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
              (let ((chapter (epub-reader-ui--chapter-data session index)))
                (or
                 (epub-reader-annotation-index-validate
                  (epub-reader-session-annotation-index session)
                  (epub-reader-annotation-id annotation)
                  index
                  (epub-reader-chapter-data-locator-index chapter))
                 (progn
                   (epub-reader-annotation-index-put
                    (epub-reader-session-annotation-index session)
                    annotation)
                   (epub-reader-annotation-index-validate
                    (epub-reader-session-annotation-index session)
                    (epub-reader-annotation-id annotation)
                    index
                    (epub-reader-chapter-data-locator-index chapter)))))
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

(defun epub-reader-annotation-list-frame (_available-width)
  "Return annotations grouped by chapter as a TextUI frame."
  (let* ((session (epub-reader-ui--panel-reader-session))
         (publication (epub-reader-session-publication session))
         (items
          (epub-reader-annotation-index-list-items
           (epub-reader-session-annotation-index session)))
         (children
          (list (list :type :text
                      :value
                      (propertize
                       (format "%s — Highlights"
                               (epub-reader-publication-title publication))
                       'face 'epub-reader-header-face))))
         previous-index)
    (dolist (item items)
      (let* ((annotation
              (epub-reader-annotation-index-item-annotation item))
             (index
              (epub-reader-annotation-index-item-chapter-index item)))
        (unless (equal index previous-index)
          (push (list :type :text
                      :value
                      (propertize
                       (epub-reader-ui--chapter-label session index)
                       'face 'epub-reader-toc-group-face))
                children)
          (setq previous-index index))
        (let* ((note (epub-reader-annotation-note annotation))
               (warning
                (if (and
                     (epub-reader-annotation-index-item-validated-p item)
                     (not (eq
                           (epub-reader-annotation-index-item-quality item)
                           'exact)))
                    "⚠ " ""))
               (excerpt-value
                (propertize
                 (format "%s“%s”" warning
                         (epub-reader-ui--short-text
                          (epub-reader-annotation-index-item-exact item) 60))
                 'epub-reader-annotation annotation
                 'mouse-face 'highlight
                 'keymap epub-reader-annotation-row-map
                 'help-echo "RET or mouse-1: jump; d: delete; e: edit note"))
               (note-value
                (and
                 (not (string-empty-p note))
                 (propertize
                  (format "Note: %s" note)
                  'epub-reader-annotation annotation
                  'mouse-face 'highlight
                  'keymap epub-reader-annotation-row-map
                  'help-echo
                  "RET or mouse-1: jump; d: delete; e: edit note"))))
          (push
           (list :type :flex :direction :column :gap 0
                 :children
                 (delq nil
                       (list
                        (list :type :text :value excerpt-value
                              :wrap 'greedy)
                        (and note-value
                             (list :type :text :value note-value
                                   :wrap 'greedy)))))
           children))))
    (unless items
      (push (list :type :text
                  :value (propertize "No highlights yet" 'face 'shadow))
            children))
    (list (list :type :flex :direction :column :gap 1
                :children (nreverse children)))))

(defun epub-reader-annotation-list--at-point ()
  "Return the annotation at point, immediately before it, or on its row."
  (or (get-text-property (point) 'epub-reader-annotation)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'epub-reader-annotation))
      (let ((position
             (text-property-not-all
              (line-beginning-position) (line-end-position)
              'epub-reader-annotation nil)))
        (and position
             (get-text-property position 'epub-reader-annotation)))))

(defun epub-reader-annotation-list--positions ()
  "Return the first buffer position of each displayed annotation."
  (let ((cursor (point-min))
        (seen (make-hash-table :test #'equal))
        positions)
    (while (< cursor (point-max))
      (let ((annotation
             (get-text-property cursor 'epub-reader-annotation)))
        (when (and annotation
                   (not (gethash (epub-reader-annotation-id annotation)
                                 seen)))
          (puthash (epub-reader-annotation-id annotation) t seen)
          (push (cons annotation cursor) positions)))
      (setq cursor
            (or (next-single-property-change
                 cursor 'epub-reader-annotation nil (point-max))
                (point-max))))
    (nreverse positions)))

(defun epub-reader-annotation-list--move (direction)
  "Move to the annotation in DIRECTION, either `next' or `previous'."
  (let* ((positions (epub-reader-annotation-list--positions))
         (current (epub-reader-annotation-list--at-point))
         (current-index
          (and current
               (cl-position (epub-reader-annotation-id current) positions
                            :key (lambda (entry)
                                   (epub-reader-annotation-id (car entry)))
                            :test #'equal)))
         (target
          (cond
           ((eq direction 'next)
            (if current-index
                (nth (1+ current-index) positions)
              (cl-find-if (lambda (entry) (> (cdr entry) (point)))
                          positions)))
           ((eq direction 'previous)
            (if current-index
                (and (> current-index 0)
                     (nth (1- current-index) positions))
              (car (last (cl-remove-if-not
                          (lambda (entry) (< (cdr entry) (point)))
                          positions)))))
           (t (error "Invalid annotation direction: %S" direction)))))
    (unless positions
      (user-error "No highlights"))
    (unless target
      (user-error "No %s highlight"
                  (if (eq direction 'next) "next" "previous")))
    (goto-char (cdr target))))

(defun epub-reader-annotation-list-next ()
  "Move point to the next highlight in the annotation list."
  (interactive)
  (epub-reader-annotation-list--move 'next))

(defun epub-reader-annotation-list-previous ()
  "Move point to the previous highlight in the annotation list."
  (interactive)
  (epub-reader-annotation-list--move 'previous))

(defun epub-reader-annotation-list--refresh (&optional selected-id)
  "Refresh this annotation list, restoring SELECTED-ID when present."
  (textui-refresh (current-buffer))
  (when (buffer-live-p epub-reader-ui--panel-view-reader)
    (with-current-buffer epub-reader-ui--panel-view-reader
      (epub-reader-ui--refit-panel-view
       (epub-reader-ui--current-session) 'annotations)))
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
  "Refresh SESSION's panel when it shows annotations, keeping SELECTED-ID."
  (when-let* ((buffer (epub-reader-ui--panel-view-buffer session 'annotations)))
    (with-current-buffer buffer
      (epub-reader-annotation-list--refresh selected-id))))

(defun epub-reader-annotation-list-activate ()
  "Press the panel tab at point, or jump to the annotation at point."
  (interactive)
  (unless (epub-reader-ui--press-panel-widget)
    (let ((annotation (epub-reader-annotation-list--at-point))
          (reader epub-reader-ui--panel-view-reader))
      (unless annotation (user-error "No annotation at point"))
      (with-current-buffer reader
        (epub-reader-ui--goto-annotation annotation))
      (epub-reader-ui--select-reader-window reader))))

(defun epub-reader-annotation-list-activate-mouse (event)
  "Move to mouse EVENT and jump to the annotation there."
  (interactive "e")
  (mouse-set-point event)
  (epub-reader-annotation-list-activate))

(defun epub-reader-annotation-list-delete ()
  "Delete the annotation at point from the sidecar and reader."
  (interactive)
  (let* ((annotation (epub-reader-annotation-list--at-point))
         (reader epub-reader-ui--panel-view-reader)
         (session (epub-reader-ui--panel-reader-session)))
    (unless annotation (user-error "No annotation at point"))
    (epub-reader-store-delete-annotation
     (epub-reader-session-store session)
     (epub-reader-annotation-id annotation))
    (setf (epub-reader-session-annotations session)
          (cl-delete (epub-reader-annotation-id annotation)
                     (epub-reader-session-annotations session)
                     :key #'epub-reader-annotation-id :test #'equal))
    (epub-reader-annotation-index-remove
     (epub-reader-session-annotation-index session)
     (epub-reader-annotation-id annotation))
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
         (reader epub-reader-ui--panel-view-reader))
    (unless annotation (user-error "No annotation at point"))
    (epub-reader-ui--panel-reader-session)
    (epub-reader-ui--edit-annotation-note reader annotation)))

(defun epub-reader-annotation-list-quit ()
  "Hide the annotation list."
  (interactive)
  (let ((reader epub-reader-ui--panel-view-reader))
    (if (buffer-live-p reader)
        (epub-reader-ui--hide-session-panel reader)
      (quit-restore-window (selected-window)))))

(defun epub-reader-annotations ()
  "Open and focus this book's highlights and notes in the panel."
  (interactive)
  (epub-reader-ui--show-panel-view 'annotations))

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
  (let* ((reader (current-buffer))
         (configuration epub-reader-ui--window-configuration)
         (group epub-reader-ui--layout-group)
         (side-windows
          (and (epub-reader-layout-live-p group)
               (epub-reader-layout-side-windows group))))
    (epub-reader-layout-with-inhibited
      (when (kill-buffer reader)
        (if (and (window-configuration-p configuration)
                 (frame-live-p (window-configuration-frame configuration)))
            (set-window-configuration configuration)
          (dolist (window side-windows)
            (when (window-live-p window)
              (ignore-errors (delete-window window)))))))))

(defun epub-reader-ui-open-and-display (file)
  "Open EPUB FILE, display its reader buffer, and return that buffer.
With `epub-reader-open-full-frame' non-nil the reader fills the selected frame
and remembers the previous window layout for `epub-reader-quit'."
  (epub-reader-layout-with-inhibited
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
      (epub-reader-ui--ensure-layout buffer)
      buffer)))

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
                 (annotation-index
                  (epub-reader-annotation-index-create annotations))
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
                         :annotation-index annotation-index
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
              (setq-local epub-reader-ui--session session)
              (unless (zerop epub-reader-text-scale)
                (text-scale-set epub-reader-text-scale)))
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
             (let ((panel-buffer
                    (and session
                         (epub-reader-session-panel-buffer session))))
               (when (buffer-live-p panel-buffer)
                 (kill-buffer panel-buffer)))
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
