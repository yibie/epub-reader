;;; epub-reader-layout.el --- Managed EPUB reader windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Keep the windows belonging to one reader session together without treating
;; unrelated user windows as part of the reader layout.

;;; Code:

(require 'cl-lib)

(cl-defstruct (epub-reader-layout-group
               (:constructor epub-reader-layout-group--create))
  "Windows managed for one reader buffer on one frame."
  reader-buffer frame active-p)

(defvar epub-reader-layout--groups nil
  "Live managed reader window groups.")

(defvar epub-reader-layout--inhibit nil
  "Non-nil while package code intentionally changes managed windows.")

(defconst epub-reader-layout--window-parameter
  'epub-reader-layout--managed
  "Window parameter holding (GROUP ROLE EXPECTED-BUFFER).")

(add-to-list 'window-persistent-parameters
             (cons epub-reader-layout--window-parameter t))

(defmacro epub-reader-layout-with-inhibited (&rest body)
  "Run BODY without interpreting its window changes as user departures."
  (declare (indent 0) (debug t))
  `(let ((epub-reader-layout--inhibit t))
     ,@body))

(defun epub-reader-layout--tag (window)
  "Return WINDOW's managed layout tag."
  (and (window-live-p window)
       (window-parameter window epub-reader-layout--window-parameter)))

(defun epub-reader-layout--group-windows (group)
  "Return live windows tagged as members of GROUP."
  (let ((frame (epub-reader-layout-group-frame group)))
    (when (frame-live-p frame)
      (cl-remove-if-not
       (lambda (window)
         (eq (car-safe (epub-reader-layout--tag window)) group))
       (window-list frame 'no-minibuffer)))))

(defun epub-reader-layout-window (group role)
  "Return GROUP's live managed window for ROLE, if any."
  (cl-find role (epub-reader-layout--group-windows group)
           :key (lambda (window)
                  (cadr (epub-reader-layout--tag window)))
           :test #'eq))

(defun epub-reader-layout-managed-window-p (window)
  "Return non-nil when WINDOW carries an EPUB layout management tag."
  (and (window-live-p window)
       (window-parameter window epub-reader-layout--window-parameter)))

(defun epub-reader-layout-side-windows (group)
  "Return GROUP's live managed windows other than its reader window."
  (cl-remove-if
   (lambda (window)
     (eq (cadr (epub-reader-layout--tag window)) 'reader))
   (epub-reader-layout--group-windows group)))

(defun epub-reader-layout-live-p (group)
  "Return non-nil when GROUP is still registered."
  (and (epub-reader-layout-group-p group)
       (epub-reader-layout-group-active-p group)
       (memq group epub-reader-layout--groups)))

(defun epub-reader-layout--install-hooks ()
  "Install global change detection while a managed group exists."
  (add-hook 'buffer-list-update-hook #'epub-reader-layout--check-windows)
  (add-hook 'window-configuration-change-hook
            #'epub-reader-layout--check-windows))

(defun epub-reader-layout--remove-hooks ()
  "Remove global change detection when no managed group exists."
  (unless epub-reader-layout--groups
    (remove-hook 'buffer-list-update-hook #'epub-reader-layout--check-windows)
    (remove-hook 'window-configuration-change-hook
                 #'epub-reader-layout--check-windows)))

(defun epub-reader-layout-create (reader-buffer frame)
  "Create a managed layout for READER-BUFFER on FRAME."
  (unless (and (buffer-live-p reader-buffer) (frame-live-p frame))
    (error "Cannot create an EPUB layout without a live buffer and frame"))
  (let ((group (epub-reader-layout-group--create
                :reader-buffer reader-buffer :frame frame :active-p t)))
    (push group epub-reader-layout--groups)
    (epub-reader-layout--install-hooks)
    (with-current-buffer reader-buffer
      (add-hook 'kill-buffer-hook
                (lambda () (epub-reader-layout-release group)) nil t))
    group))

(defun epub-reader-layout-manage-window (group window buffer role)
  "Tag WINDOW as GROUP's ROLE while it is expected to show BUFFER."
  (unless (and (epub-reader-layout-live-p group)
               (window-live-p window)
               (eq (window-frame window)
                   (epub-reader-layout-group-frame group))
               (eq (window-buffer window) buffer))
    (error "Cannot manage mismatched EPUB window %S" window))
  (set-window-parameter
   window epub-reader-layout--window-parameter (list group role buffer))
  window)

(defun epub-reader-layout--clear-window (window)
  "Remove the EPUB management tag from WINDOW."
  (when (window-live-p window)
    (set-window-parameter window epub-reader-layout--window-parameter nil)))

(defun epub-reader-layout--promote-window (window)
  "Turn a surviving side WINDOW into an ordinary user window."
  (when (window-live-p window)
    (set-window-dedicated-p window nil)
    (set-window-parameter window 'window-side nil)
    (set-window-parameter window 'window-slot nil)))

(defun epub-reader-layout-close (group &optional preserve-window)
  "Close GROUP's managed windows except PRESERVE-WINDOW.
PRESERVE-WINDOW is detached from the group and, when necessary, promoted
from a side window so the buffer selected by the user remains visible."
  (when (epub-reader-layout-group-p group)
    (epub-reader-layout-with-inhibited
      (let ((windows (epub-reader-layout--group-windows group)))
        (when (memq preserve-window windows)
          (epub-reader-layout--clear-window preserve-window)
          (epub-reader-layout--promote-window preserve-window))
        ;; Clear every tag before deleting anything so window hooks never see
        ;; a half-torn-down reader group.
        (dolist (window windows)
          (unless (eq window preserve-window)
            (epub-reader-layout--clear-window window)))
        (dolist (window windows)
          (unless (or (eq window preserve-window)
                      (not (window-live-p window)))
            (condition-case nil
                (delete-window window)
              (error nil)))))))
  preserve-window)

(defun epub-reader-layout-close-role (group role)
  "Close only GROUP's managed window having ROLE."
  (let ((window (epub-reader-layout-window group role)))
    (when (window-live-p window)
      (epub-reader-layout-with-inhibited
        (epub-reader-layout--clear-window window)
        (condition-case nil
            (delete-window window)
          (error nil))))
    window))

(defun epub-reader-layout-release (group)
  "Stop managing GROUP without killing its reader buffer."
  (when (epub-reader-layout-group-p group)
    (epub-reader-layout-with-inhibited
      (dolist (window (epub-reader-layout--group-windows group))
        (epub-reader-layout--clear-window window)))
    (setf (epub-reader-layout-group-active-p group) nil)
    (setq epub-reader-layout--groups (delq group epub-reader-layout--groups))
    (epub-reader-layout--remove-hooks)))

(defun epub-reader-layout--close-and-release (group &optional preserve-window)
  "Close and unregister GROUP, retaining PRESERVE-WINDOW if it belongs to it."
  (when (epub-reader-layout-live-p group)
    (epub-reader-layout-with-inhibited
      (epub-reader-layout-close group preserve-window)
      (epub-reader-layout-release group)))
  preserve-window)

(defun epub-reader-layout--departed-window ()
  "Return a managed window now showing an unrelated buffer."
  (catch 'departed
    (dolist (frame (frame-list))
      (when (frame-live-p frame)
        (dolist (window (window-list frame 'no-minibuffer))
          (let ((tag (epub-reader-layout--tag window)))
            (when (and tag
                       (epub-reader-layout-live-p (car tag))
                       (not (eq (window-buffer window) (nth 2 tag))))
              (throw 'departed window))))))))

(defun epub-reader-layout--check-windows (&rest _ignored)
  "Tear down a reader group after a managed window changes buffer."
  (unless epub-reader-layout--inhibit
    (let ((window (epub-reader-layout--departed-window)))
      (when window
        (let ((group (car (epub-reader-layout--tag window))))
          (epub-reader-layout--close-and-release group window)
          ;; A single command can change more than one managed window.
          (epub-reader-layout--check-windows))))))

(defun epub-reader-layout--occupied-slots (frame side)
  "Return side-window slots already occupied on FRAME's SIDE."
  (delq nil
        (mapcar
         (lambda (window)
           (and (eq (window-parameter window 'window-side) side)
                (or (window-parameter window 'window-slot) 0)))
         (window-list frame 'no-minibuffer))))

(defun epub-reader-layout--free-slot (frame side preferred)
  "Return a free side-window slot near PREFERRED on FRAME's SIDE."
  (let ((occupied (epub-reader-layout--occupied-slots frame side))
        (slot preferred))
    (while (memq slot occupied)
      (setq slot (1+ slot)))
    slot))

(defun epub-reader-layout-fit-side
    (main-width requested min-reader min-side)
  "Fit REQUESTED side width beside MAIN-WIDTH while preserving MIN-READER.
Return (side . WIDTH) for a horizontal side window.  When the remaining
horizontal width would be less than MIN-SIDE, return (bottom . 10) instead."
  (if (>= (- main-width requested) min-reader)
      (cons 'side requested)
    (let ((available (max 0 (- main-width min-reader))))
      (if (>= available min-side)
          (cons 'side available)
        (cons 'bottom 10)))))

(defun epub-reader-layout-display-side-buffer
    (group buffer role side preferred-slot width
           &optional min-reader min-side)
  "Display and select BUFFER as GROUP's side-window ROLE.
SIDE, PREFERRED-SLOT, and WIDTH control predictable placement.  An occupied
slot is not reused, so another reader or an unrelated side window is left
untouched."
  (let ((existing (epub-reader-layout-window group role)))
    (if (window-live-p existing)
        (progn
          (select-window existing)
          existing)
      (let* ((frame (epub-reader-layout-group-frame group))
             (reader-window (epub-reader-layout-window group 'reader))
             (main-width
              (window-total-width (window-main-window frame)))
             (available-width
              (if (window-live-p reader-window)
                  (min main-width (window-total-width reader-window))
                main-width))
             (fit
              (epub-reader-layout-fit-side
               available-width
               width (or min-reader 0) (or min-side 0)))
             (display-side (if (eq (car fit) 'bottom) 'bottom side))
             (size (cdr fit))
             (slot (epub-reader-layout--free-slot
                    frame display-side preferred-slot))
             (configuration (current-window-configuration frame))
             (before
              (mapcar
               (lambda (window)
                 (cons window (window-buffer window)))
               (window-list frame 'no-minibuffer)))
             window)
        (condition-case error-data
            (epub-reader-layout-with-inhibited
              (with-selected-frame frame
                (setq window
                      (display-buffer
                       buffer
                       `((display-buffer-in-side-window)
                         (side . ,display-side)
                         (slot . ,slot)
                         (,(if (eq display-side 'bottom)
                               'window-height
                             'window-width)
                          . ,size))))))
          (error
           (epub-reader-layout-with-inhibited
             (set-window-configuration configuration))
           (signal (car error-data) (cdr error-data))))
        (unless (window-live-p window)
          (epub-reader-layout-with-inhibited
            (set-window-configuration configuration))
          (user-error "Could not display the EPUB %s window" role))
        (let ((old (assq window before)))
          (when (and old (not (eq (cdr old) buffer)))
            (epub-reader-layout-with-inhibited
              (set-window-configuration configuration))
            (user-error "No free window for the EPUB %s" role)))
        (epub-reader-layout-manage-window group window buffer role)
        (select-window window)
        window))))

(provide 'epub-reader-layout)
;;; epub-reader-layout.el ends here
