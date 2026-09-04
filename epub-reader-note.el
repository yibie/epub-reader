;;; epub-reader-note.el --- Editable annotation notes for EPUB Reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A focused plain-text editor for annotation notes.  The caller supplies the
;; persistence callback and may tie the editor to a source buffer's lifetime.

;;; Code:

(require 'cl-lib)

(defcustom epub-reader-note-window-height 8
  "Requested height of the annotation note editor window."
  :type 'integer
  :group 'epub-reader)

(defconst epub-reader-note--minimum-window-height 4
  "Smallest useful total height for an editor or its source window.
This leaves room for window chrome and at least one editable or readable row.")

(defvar-local epub-reader-note--save-function nil
  "Function called with the current note when this editor is saved.")

(defvar-local epub-reader-note--source-buffer nil
  "Buffer whose lifetime owns this note editor, or nil.")

(defvar-local epub-reader-note--source-kill-function nil
  "Buffer-local source cleanup function installed for this note editor.")

(defvar-local epub-reader-note--source-query-function nil
  "Buffer-local source kill query installed for this note editor.")

(defvar-local epub-reader-note--key nil
  "Identity of this editor as (SOURCE-BUFFER . ANNOTATION-ID), or nil.")

(defvar-local epub-reader-note--anchor-window nil
  "Window split to display this editor, or nil.")

(defvar-local epub-reader-note--anchor-height nil
  "Total height of the editor's anchor before it was split, or nil.")

(defvar-keymap epub-reader-note-mode-map
  :doc "Keymap for editing an EPUB annotation note."
  "C-c C-c" #'epub-reader-note-save
  "C-c C-k" #'epub-reader-note-discard)

(define-derived-mode epub-reader-note-mode text-mode "EPUB-Note"
  "Major mode for editing one plain-text EPUB annotation note."
  (setq-local truncate-lines nil)
  (setq-local header-line-format
              "Edit note  C-c C-c: save  C-c C-k: discard")
  (visual-line-mode 1))

(defun epub-reader-note--detach-source ()
  "Remove this editor's cleanup hook from its source buffer."
  (when (and epub-reader-note--source-kill-function
             (buffer-live-p epub-reader-note--source-buffer))
    (with-current-buffer epub-reader-note--source-buffer
      (remove-hook 'kill-buffer-hook
                   epub-reader-note--source-kill-function t)
      (remove-hook 'kill-buffer-query-functions
                   epub-reader-note--source-query-function t)))
  (setq epub-reader-note--source-buffer nil
        epub-reader-note--source-kill-function nil
        epub-reader-note--source-query-function nil))

(defun epub-reader-note--close-editor (buffer)
  "Close BUFFER and its editor window using display restoration semantics."
  (let ((anchor (and (buffer-live-p buffer)
                     (buffer-local-value
                      'epub-reader-note--anchor-window buffer)))
        (anchor-height (and (buffer-live-p buffer)
                            (buffer-local-value
                             'epub-reader-note--anchor-height buffer)))
        (window
         (or (and (eq (window-buffer (selected-window)) buffer)
                  (selected-window))
             (get-buffer-window buffer t))))
    (if (window-live-p window)
        (quit-restore-window window 'kill)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (when (and (window-live-p anchor)
               (integerp anchor-height)
               (/= (window-total-height anchor) anchor-height))
      (condition-case nil
          (window-resize
           anchor (- anchor-height (window-total-height anchor)))
        (error nil)))))

(defun epub-reader-note--source-killed (editor)
  "Discard and kill EDITOR because its source buffer was killed."
  (when (buffer-live-p editor)
    (let ((discarded (with-current-buffer editor (buffer-modified-p))))
      (with-current-buffer editor
        (setq epub-reader-note--save-function nil
              epub-reader-note--source-buffer nil
              epub-reader-note--source-kill-function nil
              epub-reader-note--source-query-function nil)
        (set-buffer-modified-p nil))
      (epub-reader-note--close-editor editor)
      (when discarded
        (message "Discarded unsaved EPUB note changes because its source was killed")))))

(defun epub-reader-note--source-kill-query (editor)
  "Ask whether a modified EDITOR may be discarded with its source."
  (or (not (buffer-live-p editor))
      (with-current-buffer editor
        (or (not (buffer-modified-p))
            (yes-or-no-p "Discard unsaved EPUB note changes? ")))))

(defun epub-reader-note--fit-window-height
    (target-height requested-height minimum-height)
  "Fit editor height below TARGET-HEIGHT without exceeding REQUESTED-HEIGHT.
Prefer half the split target while allowing at least MINIMUM-HEIGHT for the
editor itself.  `split-window' remains responsible for rejecting a split that
cannot also preserve the source window's minimum height."
  (min requested-height
       (max minimum-height (/ target-height 2))))

(defun epub-reader-note--display-editor (buffer anchor-window)
  "Display BUFFER below ANCHOR-WINDOW without reusing another window."
  (let* ((anchor (if (window-live-p anchor-window)
                     anchor-window
                   (selected-window)))
         (frame (window-frame anchor))
         (existing (get-buffer-window buffer frame))
         (anchor-total-height (window-total-height anchor))
         (minimum-height
          (max window-min-height epub-reader-note--minimum-window-height))
         (anchor-height
          (epub-reader-note--fit-window-height
           anchor-total-height
           epub-reader-note-window-height minimum-height)))
    (or existing
        (let ((configuration (current-window-configuration frame))
              window)
          (when (>= (- anchor-total-height anchor-height) minimum-height)
            (condition-case nil
                (setq window
                      (split-window anchor (- anchor-height) 'below))
              (error nil)))
          (unless (window-live-p window)
            (let* ((main (window-main-window frame))
                   (main-height
                    (epub-reader-note--fit-window-height
                     (window-total-height main)
                     epub-reader-note-window-height minimum-height)))
              (condition-case nil
                  (setq window
                        (split-window
                         main (- (min anchor-height main-height)) 'below))
                (error nil))
              (when (and (window-live-p window)
                         (< (window-total-height anchor)
                            anchor-total-height))
                (condition-case nil
                    (window-resize
                     anchor
                     (- anchor-total-height
                        (window-total-height anchor)))
                  (error nil))
                (when (< (window-total-height anchor) anchor-total-height)
                  (set-window-configuration configuration)
                  (setq window nil)))))
          (unless (window-live-p window)
            (user-error "Could not display the EPUB note editor"))
          (condition-case error-data
              (with-selected-frame frame
                (window--display-buffer buffer window 'window nil)
                (with-current-buffer buffer
                  (setq-local epub-reader-note--anchor-window anchor
                              epub-reader-note--anchor-height
                              anchor-total-height)))
            (error
             (set-window-configuration configuration)
             (signal (car error-data) (cdr error-data))))
          window))))

(defun epub-reader-note--find-editor (key)
  "Return the live note editor identified by KEY."
  (and key
       (cl-find-if
        (lambda (buffer)
          (and (buffer-live-p buffer)
               (equal (buffer-local-value 'epub-reader-note--key buffer)
                      key)))
        (buffer-list))))

(defun epub-reader-note-save ()
  "Save this note through its caller-provided callback and exit."
  (interactive)
  (unless (derived-mode-p 'epub-reader-note-mode)
    (user-error "Not in an EPUB note editor"))
  (unless (functionp epub-reader-note--save-function)
    (user-error "This EPUB note can no longer be saved"))
  (let ((buffer (current-buffer))
        (save-function epub-reader-note--save-function)
        (note (buffer-substring-no-properties (point-min) (point-max))))
    ;; Leave the editor intact when persistence fails so the text can be
    ;; recovered or discarded explicitly.
    (funcall save-function note)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq epub-reader-note--save-function nil)
        (set-buffer-modified-p nil))
      (epub-reader-note--close-editor buffer))))

(defun epub-reader-note-discard ()
  "Discard this note's edits and kill the editor buffer."
  (interactive)
  (unless (derived-mode-p 'epub-reader-note-mode)
    (user-error "Not in an EPUB note editor"))
  (let ((buffer (current-buffer)))
    (setq epub-reader-note--save-function nil)
    (set-buffer-modified-p nil)
    (epub-reader-note--close-editor buffer))
  (message "Highlight note changes discarded"))

(defun epub-reader-note-edit
    (note save-function &optional source-buffer anchor-window key)
  "Edit plain-text NOTE and call SAVE-FUNCTION with the saved contents.
When SOURCE-BUFFER is non-nil, killing it discards and kills the editor.
Display below ANCHOR-WINDOW when possible.  KEY identifies one annotation
within SOURCE-BUFFER so repeated edits reuse the same editor."
  (unless (stringp note)
    (error "EPUB note must be a string: %S" note))
  (unless (functionp save-function)
    (error "EPUB note save callback must be a function: %S" save-function))
  (when (and source-buffer (not (buffer-live-p source-buffer)))
    (user-error "The EPUB reader buffer has been closed"))
  (let* ((editor-key (and source-buffer key (cons source-buffer key)))
         (existing (epub-reader-note--find-editor editor-key))
         (anchor (or (and (window-live-p anchor-window) anchor-window)
                     (and source-buffer (get-buffer-window source-buffer))
                     (selected-window))))
    (if existing
        (let ((window (epub-reader-note--display-editor existing anchor)))
          (select-window window)
          existing)
      (let ((buffer (generate-new-buffer "*EPUB Note*")))
        (with-current-buffer buffer
          (epub-reader-note-mode)
          (setq-local epub-reader-note--save-function save-function
                      epub-reader-note--key editor-key)
          (insert note)
          (goto-char (point-max))
          (set-buffer-modified-p nil)
          (add-hook 'kill-buffer-hook #'epub-reader-note--detach-source nil t))
        (when source-buffer
          (let ((cleanup (lambda () (epub-reader-note--source-killed buffer)))
                (query (lambda ()
                         (epub-reader-note--source-kill-query buffer))))
            (with-current-buffer buffer
              (setq-local epub-reader-note--source-buffer source-buffer
                          epub-reader-note--source-kill-function cleanup
                          epub-reader-note--source-query-function query))
            (with-current-buffer source-buffer
              (add-hook 'kill-buffer-hook cleanup nil t)
              (add-hook 'kill-buffer-query-functions query nil t))))
        (condition-case error-data
            (let ((window (epub-reader-note--display-editor buffer anchor)))
              (select-window window)
              buffer)
          (error
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq epub-reader-note--save-function nil)
               (set-buffer-modified-p nil))
             (kill-buffer buffer))
           (signal (car error-data) (cdr error-data))))))))

(provide 'epub-reader-note)
;;; epub-reader-note.el ends here
