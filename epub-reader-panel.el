;;; epub-reader-panel.el --- Overlay and window EPUB panels -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Present one auxiliary buffer beside a reader.  Callers see an opaque panel
;; handle; child-frame creation, ordinary-window fallback, focus restoration,
;; and lifetime cleanup stay inside this module.  A caller that already owns
;; window layout may inject only the display operation.

;;; Code:

(require 'cl-lib)

(defcustom epub-reader-panel-display 'auto
  "How EPUB auxiliary panels are presented.
`auto' uses a child frame on graphical displays and an ordinary side window
elsewhere.  `child-frame' requests the same child-frame presentation but also
falls back to a side window when child frames are unavailable.  `side-window'
and `bottom' always use an ordinary window in that position."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "Child frame, with fallback" child-frame)
                 (const :tag "Right side window" side-window)
                 (const :tag "Bottom window" bottom))
  :group 'epub-reader)

(defcustom epub-reader-panel-width 40
  "Requested width of a side-window or child-frame panel.
The value is measured in columns."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-panel-height 12
  "Requested height of a bottom panel, measured in lines."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-horizontal-margin 2
  "Horizontal inset of a child-frame panel, measured in columns."
  :type 'natnum
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-vertical-margin 1
  "Vertical inset of a child-frame panel, measured in lines."
  :type 'natnum
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-max-width-ratio 0.42
  "Maximum fraction of the reader width occupied by one child frame."
  :type 'number
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-max-height-ratio 0.75
  "Maximum fraction of the reader height occupied by one child frame."
  :type 'number
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-min-height 6
  "Minimum fitted child-frame height, measured in lines."
  :type 'natnum
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-inner-margin 1
  "Horizontal inner margin of a child-frame panel, measured in columns."
  :type 'natnum
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-min-reader-width 60
  "Minimum reader width at which a new child-frame panel is opened.
Narrower readers use the ordinary-window fallback, which can place a panel at
the bottom instead of covering most of the text.  An existing child frame
continues to scale proportionally when its reader is resized."
  :type 'natnum
  :group 'epub-reader)

(defcustom epub-reader-panel-child-frame-border-width 1
  "Border width of a child-frame panel, measured in pixels."
  :type 'natnum
  :group 'epub-reader)

(defcustom epub-reader-panel-show-mode-line nil
  "Whether EPUB child-frame panels display their buffer's mode line.
This affects child frames only; ordinary side and bottom windows retain their
normal buffer or layout-specific mode-line policy."
  :type 'boolean
  :group 'epub-reader)

(defface epub-reader-panel-child-frame-border-face
  '((t (:inherit shadow)))
  "Face whose foreground colors an EPUB panel child-frame border."
  :group 'epub-reader)

(defun epub-reader-panel-child-frame-geometry (reader-window &optional side)
  "Return child-frame geometry overlaid on READER-WINDOW.
The result is a plist containing `:left', `:top', `:width', and `:height'
in pixels, relative to READER-WINDOW's frame.  The panel floats inside the
requested edge of the reader window and never resizes that window.
Vertically it stays within the window body, so it covers neither the header
line nor the mode line."
  (unless (window-live-p reader-window)
    (error "Cannot measure a dead EPUB reader window"))
  (pcase-let* ((`(,left ,_ ,right ,_)
                (window-pixel-edges reader-window))
               (`(,_ ,top ,_ ,bottom)
                (window-body-pixel-edges reader-window))
               (frame (window-frame reader-window))
               (whole-width (max 1 (- right left)))
               (whole-height (max 1 (- bottom top)))
               (horizontal-margin
                (min (* epub-reader-panel-child-frame-horizontal-margin
                        (frame-char-width frame))
                     (/ (max 0 (1- whole-width)) 2)))
               (vertical-margin
                (min (* epub-reader-panel-child-frame-vertical-margin
                        (frame-char-height frame))
                     (/ (max 0 (1- whole-height)) 2)))
               (available-width
                (max 1 (- whole-width (* 2 horizontal-margin))))
               (requested-width
                (* (max 1 epub-reader-panel-width)
                   (frame-char-width frame)))
               (maximum-width
                (max 1
                     (floor (* whole-width
                               epub-reader-panel-child-frame-max-width-ratio))))
               (available-height
                (max 1 (- whole-height (* 2 vertical-margin))))
               (maximum-height
                (max 1
                     (floor (* whole-height
                               epub-reader-panel-child-frame-max-height-ratio))))
               (width (min available-width requested-width maximum-width)))
    (list :left (if (eq side 'left)
                    (+ left horizontal-margin)
                  (- right horizontal-margin width))
          :top (+ top vertical-margin)
          :width width
          :height (min available-height maximum-height))))

(defcustom epub-reader-panel-child-frame-geometry-function
  #'epub-reader-panel-child-frame-geometry
  "Function used to calculate an EPUB panel child frame's geometry.
It receives the originating reader window and the anchor side, either `left'
or `right', and returns the pixel plist
documented by `epub-reader-panel-child-frame-geometry'."
  :type 'function
  :group 'epub-reader)

(cl-defstruct (epub-reader-panel--handle
               (:constructor epub-reader-panel--make))
  "Private presentation state behind an EPUB panel handle."
  active-p visible-p buffer reader-buffer reader-window parent-frame
  child-frame-side presentation kind ordinary-display-function
  ordinary-close-function
  reader-kill-function panel-kill-function)

(defvar epub-reader-panel--panels nil
  "Active EPUB panel handles.")

(defvar epub-reader-panel--syncing nil
  "Non-nil while child-frame panel geometry is being synchronized.")

(defun epub-reader-panel--ordinary-display (buffer placement reader-window)
  "Display BUFFER at PLACEMENT beside READER-WINDOW and return its window."
  (let* ((side (if (eq placement 'bottom) 'bottom 'right))
         (size-key (if (eq side 'bottom) 'window-height 'window-width))
         (size (if (eq side 'bottom)
                   (max 1 epub-reader-panel-height)
                 (max 1 epub-reader-panel-width))))
    (with-selected-frame (window-frame reader-window)
      (display-buffer
       buffer
       `((display-buffer-in-side-window)
         (side . ,side)
         (slot . 0)
         (,size-key . ,size)
         (window-parameters . ((epub-reader-panel . t))))))))

(defun epub-reader-panel--validate-geometry (geometry)
  "Validate child-frame GEOMETRY and return it."
  (unless (and (natnump (plist-get geometry :left))
               (natnump (plist-get geometry :top))
               (natnump (plist-get geometry :width))
               (> (plist-get geometry :width) 0)
               (natnump (plist-get geometry :height))
               (> (plist-get geometry :height) 0))
    (error "Invalid EPUB panel child-frame geometry: %S" geometry))
  geometry)

(defun epub-reader-panel--apply-child-frame-border (frame)
  "Apply the configured EPUB panel border color to FRAME."
  (set-face-background
   'child-frame-border
   (or (face-foreground
        'epub-reader-panel-child-frame-border-face frame t)
       (face-foreground 'shadow frame t)
       "gray50")
   frame))

(defun epub-reader-panel--sync-child-frame
    (frame reader-window side &optional force)
  "Size and position child FRAME inside READER-WINDOW.
Sizing is pixelwise.  Positioning uses FRAME's measured outer dimensions, not
the requested dimensions, so native borders cannot push it outside its parent.
Skip unchanged automatic synchronization unless FORCE is non-nil.  Return
non-nil when native frame geometry was applied."
  (when (and (frame-live-p frame) (window-live-p reader-window))
    (let* ((geometry
            (epub-reader-panel--validate-geometry
             (funcall epub-reader-panel-child-frame-geometry-function
                      reader-window side)))
           (parent (window-frame reader-window))
           (target-right (+ (plist-get geometry :left)
                            (plist-get geometry :width)))
           (target-top (plist-get geometry :top))
           (maximum-height (plist-get geometry :height))
           (line-height (max 1 (frame-char-height frame)))
           (parent-width (frame-pixel-width parent))
           (parent-height (frame-pixel-height parent))
           (signature (list geometry parent-width parent-height line-height
                            side)))
      (when (or force
                (not (equal
                      signature
                      (frame-parameter
                       frame 'epub-reader-panel--geometry-cache))))
        (let ((frame-resize-pixelwise t)
              (epub-reader-panel--syncing t))
          (set-frame-width frame (plist-get geometry :width) nil t)
          (set-frame-height frame maximum-height nil t)
          (let* ((maximum-lines (max 1 (/ maximum-height line-height)))
                 (minimum-lines
                  (min maximum-lines
                       (max 1 epub-reader-panel-child-frame-min-height))))
            (fit-frame-to-buffer
             frame maximum-lines minimum-lines nil nil 'vertically))
          (let* ((actual-width (frame-pixel-width frame))
                 (actual-height (frame-pixel-height frame))
                 (requested-left
                  (if (eq side 'left)
                      (plist-get geometry :left)
                    (- target-right actual-width)))
                 (left (max 0
                            (min requested-left
                                 (max 0 (- parent-width actual-width)))))
                 (top (max 0
                           (min target-top
                                (max 0 (- parent-height actual-height))))))
            (set-frame-position frame left top))
          (set-frame-parameter
           frame 'epub-reader-panel--geometry-cache signature)
          t)))))

(defun epub-reader-panel--prepare-child-window (frame buffer)
  "Prepare FRAME's root window to display interactive BUFFER cleanly."
  ;; Reassert frame chrome after creation: a global `tab-bar-mode' can apply
  ;; its defaults while a new frame is initialized, after initial parameters
  ;; have been merged.
  (set-frame-parameter frame 'tab-bar-lines 0)
  (let ((window (frame-root-window frame)))
    (set-window-buffer window buffer)
    (set-window-dedicated-p window t)
    (set-window-parameter window 'no-other-window t)
    (set-window-parameter window 'no-delete-other-windows t)
    (set-window-parameter window 'mode-line-format
                          (unless epub-reader-panel-show-mode-line 'none))
    (set-window-parameter window 'tab-line-format 'none)
    (set-window-fringes window 0 0 nil t)
    (set-window-margins window
                        epub-reader-panel-child-frame-inner-margin
                        epub-reader-panel-child-frame-inner-margin)
    (set-window-scroll-bars window 0 nil 0 nil t)))

(defun epub-reader-panel--child-frame (buffer reader-window side)
  "Display BUFFER in a child frame over READER-WINDOW.
Return the new child frame."
  (let* ((parent (window-frame reader-window))
         (geometry
          (funcall epub-reader-panel-child-frame-geometry-function
                   reader-window side))
         frame)
    (epub-reader-panel--validate-geometry geometry)
    (condition-case error-data
        (let ((frame-resize-pixelwise t))
          (setq frame
                (make-frame
                 `((parent-frame . ,parent)
                   ;; Do not let display defaults override the Lisp parent.
                   (parent-id . nil)
                   (minibuffer . ,(minibuffer-window parent))
                   (visibility . nil)
                   ;; Mapping the panel must not steal focus.  Explicit
                   ;; `epub-reader-panel-focus' calls may still select it.
                   (no-focus-on-map . t)
                   (undecorated . t)
                   (no-other-frame . t)
                   (skip-taskbar . t)
                   (desktop-dont-save . t)
                   (unsplittable . t)
                   (border-width . 0)
                   (left-fringe . 0)
                   (right-fringe . 0)
                   (vertical-scroll-bars . nil)
                   (horizontal-scroll-bars . nil)
                   (scroll-bar-width . 0)
                   (scroll-bar-height . 0)
                   (right-divider-width . 0)
                   (bottom-divider-width . 0)
                   (menu-bar-lines . 0)
                   (tool-bar-lines . 0)
                   (tab-bar-lines . 0)
                   (internal-border-width . 0)
                   (child-frame-border-width
                    . ,epub-reader-panel-child-frame-border-width)
                   (width . 1)
                   (height . 1))))
          (unless (eq (frame-parent frame) parent)
            (error "EPUB panel frame was not attached to its reader frame"))
          (epub-reader-panel--prepare-child-window frame buffer)
          (epub-reader-panel--apply-child-frame-border frame)
          (epub-reader-panel--sync-child-frame frame reader-window side t)
          (make-frame-visible frame)
          ;; Native decorations and scale factors become reliable only after
          ;; mapping, so correct the initial estimate once the frame is shown.
          (epub-reader-panel--sync-child-frame frame reader-window side t)
          frame)
      (error
       (when (frame-live-p frame)
         (delete-frame frame t))
       (signal (car error-data) (cdr error-data))))))

(defun epub-reader-panel--select-window (window &optional force-native-focus)
  "Select live WINDOW and its frame, returning WINDOW.
When FORCE-NATIVE-FOCUS is non-nil, explicitly return the window-system input
focus even if Emacs already considers WINDOW's frame selected."
  (when (window-live-p window)
    (let ((frame (window-frame window)))
      (when (and (display-graphic-p frame)
                 (or force-native-focus
                     (frame-parent frame)
                     (not (eq frame (selected-frame)))))
        (select-frame-set-input-focus frame))
      (select-window window))
    window))

(defun epub-reader-panel--origin-live-p (panel)
  "Return non-nil when PANEL's originating reader is still displayed."
  (let ((reader (epub-reader-panel--handle-reader-buffer panel))
        (window (epub-reader-panel--handle-reader-window panel))
        (parent (epub-reader-panel--handle-parent-frame panel)))
    (and (buffer-live-p reader)
         (frame-live-p parent)
         (window-live-p window)
         (eq (window-frame window) parent)
         (eq (window-buffer window) reader))))

(defun epub-reader-panel-live-p (panel)
  "Return non-nil when reusable PANEL and its originating reader are live.
A hidden panel remains live until it is destroyed or an owning buffer, window,
or frame dies."
  (and (epub-reader-panel--handle-p panel)
       (epub-reader-panel--handle-active-p panel)
       (epub-reader-panel--origin-live-p panel)
       (let ((presentation
              (epub-reader-panel--handle-presentation panel))
             (buffer (epub-reader-panel--handle-buffer panel)))
         (and (buffer-live-p buffer)
              (pcase (epub-reader-panel--handle-kind panel)
                ('child-frame
                 (and (frame-live-p presentation)
                      (eq (frame-parent presentation)
                          (epub-reader-panel--handle-parent-frame panel))
                      (eq (window-buffer (frame-root-window presentation))
                          buffer)))
                ((or 'side-window 'bottom)
                 (or (null presentation)
                     (and (window-live-p presentation)
                          (eq (window-buffer presentation) buffer)))))))))

(defun epub-reader-panel-visible-p (panel)
  "Return non-nil when live PANEL currently has a visible presentation."
  (and (epub-reader-panel-live-p panel)
       (epub-reader-panel--handle-visible-p panel)
       (let ((presentation
              (epub-reader-panel--handle-presentation panel)))
         (pcase (epub-reader-panel--handle-kind panel)
           ('child-frame (frame-visible-p presentation))
           ((or 'side-window 'bottom) (window-live-p presentation))))))

(defun epub-reader-panel--remove-buffer-hook (buffer function)
  "Remove buffer-local kill hook FUNCTION from live BUFFER."
  (when (and function (buffer-live-p buffer))
    (with-current-buffer buffer
      (remove-hook 'kill-buffer-hook function t))))

(defun epub-reader-panel--adopt-buffer (panel buffer)
  "Transfer PANEL's content-buffer lifetime ownership to BUFFER."
  (let ((old-buffer (epub-reader-panel--handle-buffer panel))
        (kill-function
         (epub-reader-panel--handle-panel-kill-function panel)))
    (epub-reader-panel--remove-buffer-hook old-buffer kill-function)
    (setf (epub-reader-panel--handle-buffer panel) buffer)
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook kill-function nil t))))

(defun epub-reader-panel--close-ordinary-presentation (panel)
  "Remove PANEL's ordinary-window presentation, if any."
  (let ((presentation (epub-reader-panel--handle-presentation panel)))
    (setf (epub-reader-panel--handle-presentation panel) nil
          (epub-reader-panel--handle-visible-p panel) nil)
    (when (and (window-live-p presentation)
               (eq (window-buffer presentation)
                   (epub-reader-panel--handle-buffer panel)))
      (condition-case nil
          (let ((close-function
                 (epub-reader-panel--handle-ordinary-close-function panel)))
            (if close-function
                (funcall close-function presentation)
              (quit-window nil presentation)))
        (error nil)))))

(defun epub-reader-panel--teardown (panel restore-focus)
  "Tear down PANEL and optionally RESTORE-FOCUS to its reader."
  (when (and (epub-reader-panel--handle-p panel)
             (epub-reader-panel--handle-active-p panel))
    (setf (epub-reader-panel--handle-active-p panel) nil)
    (setq epub-reader-panel--panels
          (delq panel epub-reader-panel--panels))
    (epub-reader-panel--remove-buffer-hook
     (epub-reader-panel--handle-reader-buffer panel)
     (epub-reader-panel--handle-reader-kill-function panel))
    (epub-reader-panel--remove-buffer-hook
     (epub-reader-panel--handle-buffer panel)
     (epub-reader-panel--handle-panel-kill-function panel))
    (let ((presentation
           (epub-reader-panel--handle-presentation panel)))
      (pcase (epub-reader-panel--handle-kind panel)
        ('child-frame
         (setf (epub-reader-panel--handle-presentation panel) nil
               (epub-reader-panel--handle-visible-p panel) nil)
         (when (frame-live-p presentation)
           (delete-frame presentation t)))
        ((or 'side-window 'bottom)
         (epub-reader-panel--close-ordinary-presentation panel))))
    (unless epub-reader-panel--panels
      (remove-hook 'window-configuration-change-hook
                   #'epub-reader-panel--sweep)
      (remove-hook 'window-size-change-functions
                   #'epub-reader-panel--frame-resized)
      (remove-hook 'delete-frame-functions
                   #'epub-reader-panel--frame-deleted))
    (when (and restore-focus
               (epub-reader-panel--origin-live-p panel))
      (epub-reader-panel--select-window
       (epub-reader-panel--handle-reader-window panel) t))))

(defun epub-reader-panel--sweep (&rest _ignored)
  "Close active panels whose reader or presentation has disappeared."
  (dolist (panel (copy-sequence epub-reader-panel--panels))
    (unless (epub-reader-panel-live-p panel)
      (epub-reader-panel--teardown panel nil))))

(defun epub-reader-panel--frame-resized (frame)
  "Reposition child-frame panels whose parent FRAME was resized."
  (unless epub-reader-panel--syncing
    (let ((epub-reader-panel--syncing t))
      (dolist (panel (copy-sequence epub-reader-panel--panels))
        (when (and (epub-reader-panel-visible-p panel)
                   (eq (epub-reader-panel--handle-kind panel) 'child-frame)
                   (eq (epub-reader-panel--handle-parent-frame panel) frame))
          (condition-case nil
              (epub-reader-panel--sync-child-frame
               (epub-reader-panel--handle-presentation panel)
               (epub-reader-panel--handle-reader-window panel)
               (epub-reader-panel--handle-child-frame-side panel))
            (error nil)))))))

(defun epub-reader-panel--frame-deleted (frame)
  "Close active panels owned by or presented on deleted FRAME."
  (dolist (panel (copy-sequence epub-reader-panel--panels))
    (when (or (eq frame (epub-reader-panel--handle-parent-frame panel))
              (eq frame (epub-reader-panel--handle-presentation panel)))
      ;; Avoid asking Emacs to delete a child frame already being deleted.
      (when (eq frame (epub-reader-panel--handle-presentation panel))
        (setf (epub-reader-panel--handle-presentation panel) nil))
      (epub-reader-panel--teardown panel nil))))

(defun epub-reader-panel--install-lifetime-hooks (panel)
  "Install lifetime cleanup hooks for PANEL."
  (let ((reader-hook
         (lambda () (epub-reader-panel--teardown panel nil)))
        (panel-hook
         ;; Deleting a selected ordinary side window already selects its
         ;; sibling.  Selecting during that buffer's kill hook can instead
         ;; make Emacs redisplay the reader through the dying window.  A child
         ;; frame has no sibling selection, so restore its parent explicitly.
         (lambda ()
           (epub-reader-panel--teardown
            panel
            (eq (epub-reader-panel--handle-kind panel) 'child-frame)))))
    (setf (epub-reader-panel--handle-reader-kill-function panel) reader-hook
          (epub-reader-panel--handle-panel-kill-function panel) panel-hook)
    (with-current-buffer (epub-reader-panel--handle-reader-buffer panel)
      (add-hook 'kill-buffer-hook reader-hook nil t))
    (with-current-buffer (epub-reader-panel--handle-buffer panel)
      (add-hook 'kill-buffer-hook panel-hook nil t)))
  (add-hook 'window-configuration-change-hook #'epub-reader-panel--sweep)
  (add-hook 'window-size-change-functions #'epub-reader-panel--frame-resized)
  (add-hook 'delete-frame-functions #'epub-reader-panel--frame-deleted))

(defun epub-reader-panel-open
    (buffer reader-window &optional display-function close-function
            child-frame-side)
  "Present BUFFER from READER-WINDOW and return an opaque panel handle.

DISPLAY-FUNCTION is an optional layout seam for ordinary-window presentation.
It is called as (FUNCTION BUFFER PLACEMENT READER-WINDOW), where PLACEMENT is
`side-window' or `bottom', and must return a new live window displaying BUFFER.
When omitted, this module's ordinary side-window adapter is used.

CLOSE-FUNCTION complements an injected DISPLAY-FUNCTION when the caller owns
the ordinary-window layout.  It receives the displayed window and must remove
that presentation.  When omitted, `quit-window' closes ordinary presentations.

CHILD-FRAME-SIDE anchors a child frame to `left' or `right' inside the reader.
It defaults to `right' and does not affect ordinary-window placement.

`epub-reader-panel-display' selects the presentation.  Both `auto' and an
explicit `child-frame' request fall back to `side-window' if a child frame is
not available or cannot be created."
  (unless (and (buffer-live-p buffer)
               (window-live-p reader-window)
               (buffer-live-p (window-buffer reader-window)))
    (error "An EPUB panel needs a live buffer and reader window"))
  (when (eq buffer (window-buffer reader-window))
    (error "An EPUB panel buffer must differ from its reader buffer"))
  (let* ((reader-buffer (window-buffer reader-window))
         (parent (window-frame reader-window))
         (requested epub-reader-panel-display)
         (try-child
          (and (memq requested '(auto child-frame))
               (display-graphic-p parent)
               (>= (window-body-width reader-window)
                   epub-reader-panel-child-frame-min-reader-width)))
         presentation
         kind)
    (when try-child
      (condition-case nil
          (setq presentation
                (epub-reader-panel--child-frame
                 buffer reader-window (or child-frame-side 'right))
                kind 'child-frame)
        (error nil)))
    (unless presentation
      (setq kind (if (eq requested 'bottom) 'bottom 'side-window)
            presentation
            (funcall (or display-function
                         #'epub-reader-panel--ordinary-display)
                     buffer kind reader-window))
      (unless (and (window-live-p presentation)
                   (not (eq presentation reader-window))
                   (eq (window-buffer presentation) buffer))
        (error "EPUB panel display callback returned an invalid window")))
    (let ((panel
           (epub-reader-panel--make
            :active-p t
            :visible-p t
            :buffer buffer
            :reader-buffer reader-buffer
            :reader-window reader-window
            :parent-frame parent
            :child-frame-side (or child-frame-side 'right)
            :presentation presentation
            :kind kind
            :ordinary-display-function
            (or display-function #'epub-reader-panel--ordinary-display)
            :ordinary-close-function close-function)))
      (push panel epub-reader-panel--panels)
      (epub-reader-panel--install-lifetime-hooks panel)
      (epub-reader-panel-focus panel)
      panel)))

(defun epub-reader-panel-show (panel)
  "Show reusable PANEL without selecting it and return its presentation.
An ordinary-window presentation is recreated through the display adapter that
was supplied to `epub-reader-panel-open'.  A dead or destroyed panel returns
nil."
  (when (epub-reader-panel-live-p panel)
    (let ((presentation
           (epub-reader-panel--handle-presentation panel)))
      (pcase (epub-reader-panel--handle-kind panel)
        ('child-frame
         (unless (frame-visible-p presentation)
           (make-frame-visible presentation)
           (epub-reader-panel--prepare-child-window
            presentation (epub-reader-panel--handle-buffer panel))
           (epub-reader-panel--sync-child-frame
            presentation
            (epub-reader-panel--handle-reader-window panel)
            (epub-reader-panel--handle-child-frame-side panel)
            t)))
        ((or 'side-window 'bottom)
         (unless (window-live-p presentation)
           (setq presentation
                 (funcall
                  (epub-reader-panel--handle-ordinary-display-function panel)
                  (epub-reader-panel--handle-buffer panel)
                  (epub-reader-panel--handle-kind panel)
                  (epub-reader-panel--handle-reader-window panel)))
           (unless (and (window-live-p presentation)
                        (not (eq presentation
                                 (epub-reader-panel--handle-reader-window
                                  panel)))
                        (eq (window-buffer presentation)
                            (epub-reader-panel--handle-buffer panel)))
             (error "EPUB panel display callback returned an invalid window"))
           (setf (epub-reader-panel--handle-presentation panel)
                 presentation))))
      (setf (epub-reader-panel--handle-visible-p panel) t)
      presentation)))

(defun epub-reader-panel-hide (panel)
  "Hide reusable PANEL, restore reader focus, and return its reader window.
The handle, buffers, hooks, and child frame remain owned by PANEL.  Ordinary
windows are removed and recreated by `epub-reader-panel-show'."
  (when (epub-reader-panel-live-p panel)
    (pcase (epub-reader-panel--handle-kind panel)
      ('child-frame
       (setf (epub-reader-panel--handle-visible-p panel) nil)
       (make-frame-invisible
        (epub-reader-panel--handle-presentation panel)))
      ((or 'side-window 'bottom)
       (epub-reader-panel--close-ordinary-presentation panel)))
    (when (epub-reader-panel--origin-live-p panel)
      (epub-reader-panel--select-window
       (epub-reader-panel--handle-reader-window panel) t))))

(defun epub-reader-panel-focus (panel)
  "Show and focus PANEL, returning its presentation window, or nil if dead."
  (let ((presentation (epub-reader-panel-show panel)))
    (when presentation
      (epub-reader-panel--select-window
       (if (eq (epub-reader-panel--handle-kind panel) 'child-frame)
           (frame-root-window presentation)
         presentation)))))

(defun epub-reader-panel-set-buffer (panel buffer)
  "Switch live PANEL to BUFFER without changing its visibility or focus.
BUFFER must be live and distinct from PANEL's originating reader buffer.  The
panel assumes lifetime ownership of BUFFER and releases its previous content
buffer.  Return PANEL, or nil when PANEL is no longer live."
  (unless (buffer-live-p buffer)
    (error "An EPUB panel view needs a live buffer"))
  (when (epub-reader-panel-live-p panel)
    (when (eq buffer (epub-reader-panel--handle-reader-buffer panel))
      (error "An EPUB panel buffer must differ from its reader buffer"))
    (unless (eq buffer (epub-reader-panel--handle-buffer panel))
      (let* ((presentation
              (epub-reader-panel--handle-presentation panel))
             (kind (epub-reader-panel--handle-kind panel))
             (ordinary-visible-p
              (and (memq kind '(side-window bottom))
                   (epub-reader-panel-visible-p panel)))
             (selected (selected-window))
             (selected-presentation-p (eq selected presentation)))
        (pcase (epub-reader-panel--handle-kind panel)
          ('child-frame
           (epub-reader-panel--prepare-child-window presentation buffer))
          ((or 'side-window 'bottom)
           (when ordinary-visible-p
             ;; The injected layout adapter may associate presentation state
             ;; with the old buffer.  Re-enter the same close/display seam
             ;; instead of mutating its window behind its back.
             (epub-reader-panel--close-ordinary-presentation panel))))
        (epub-reader-panel--adopt-buffer panel buffer)
        (when ordinary-visible-p
          (let ((new-presentation (epub-reader-panel-show panel)))
            (epub-reader-panel--select-window
             (if selected-presentation-p new-presentation selected))))
        (when (and (eq kind 'child-frame)
                   (epub-reader-panel-visible-p panel))
          (epub-reader-panel--sync-child-frame
           presentation
           (epub-reader-panel--handle-reader-window panel)
           (epub-reader-panel--handle-child-frame-side panel)
           t))))
    panel))

(defun epub-reader-panel-origin-window (panel)
  "Return PANEL's live originating reader window, or nil.
This is the stable bridge from a child-frame command back to its parent
reader; callers need not inspect the presentation kind."
  (when (and (epub-reader-panel--handle-p panel)
             (epub-reader-panel--handle-active-p panel)
             (epub-reader-panel--origin-live-p panel))
    (epub-reader-panel--handle-reader-window panel)))

(defun epub-reader-panel-refit (panel)
  "Refit live child-frame PANEL to its reader and current contents.
Ordinary-window and dead panels are left unchanged."
  (when (and (epub-reader-panel-live-p panel)
             (eq (epub-reader-panel--handle-kind panel) 'child-frame))
    (epub-reader-panel--sync-child-frame
     (epub-reader-panel--handle-presentation panel)
     (epub-reader-panel--handle-reader-window panel)
     (epub-reader-panel--handle-child-frame-side panel)
     t)
    panel))

(defun epub-reader-panel-destroy (panel)
  "Destroy PANEL, restore reader focus, and return that reader window.
Destroying an already destroyed panel is harmless and returns nil."
  (when (and (epub-reader-panel--handle-p panel)
             (epub-reader-panel--handle-active-p panel))
    (let ((reader-window
           (epub-reader-panel--handle-reader-window panel))
          (origin-live-p (epub-reader-panel--origin-live-p panel)))
      (epub-reader-panel--teardown panel t)
      (and origin-live-p (window-live-p reader-window) reader-window))))

(defun epub-reader-panel-close (panel)
  "Compatibility operation that destroys PANEL and restores reader focus.
New session owners should use `epub-reader-panel-hide' for a reusable toggle
and `epub-reader-panel-destroy' for final teardown."
  (epub-reader-panel-destroy panel))

(provide 'epub-reader-panel)
;;; epub-reader-panel.el ends here
