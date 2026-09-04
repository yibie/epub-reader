;;; epub-reader-note-test.el --- Annotation note editor tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-test-helper)

(defun epub-reader-note-test--source-position (key offset)
  "Return the rendered position for semantic block KEY at source OFFSET."
  (cl-loop for position from (point-min) below (point-max)
           for source = (get-text-property position 'epub-reader-source)
           when (and (epub-reader-locator-source-p source)
                     (equal (aref source 1) key)
                     (= (aref source 2) offset))
           return position))

(defun epub-reader-note-test--annotation-position ()
  "Return the first position carrying an annotation row property."
  (cl-loop for position from (point-min) below (point-max)
           when (get-text-property position 'epub-reader-annotation)
           return position))

(defun epub-reader-note-test--annotation-line-count (annotation-id)
  "Return the number of rendered lines belonging to ANNOTATION-ID."
  (length
   (delete-dups
    (cl-loop for position from (point-min) below (point-max)
             for annotation = (get-text-property
                               position 'epub-reader-annotation)
             when (and annotation
                       (equal (epub-reader-annotation-id annotation)
                              annotation-id))
             collect (line-number-at-pos position)))))

(defun epub-reader-note-test--editor-buffers ()
  "Return live EPUB note editor buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer
       (derived-mode-p 'epub-reader-note-mode)))
   (buffer-list)))

(defun epub-reader-note-test--open-annotated-reader (&optional undisplayed)
  "Open a temporary annotated reader and return its test resources.
Use `epub-reader-ui-open' instead of displaying the reader when UNDISPLAYED is
non-nil."
  (let ((directory (make-temp-file "epub-reader-notes-" t))
        (source (make-temp-file "epub-reader-note-book-" nil ".epub"))
        reader annotation)
    (copy-file (epub-reader-test-fixture "language-mix.epub") source t)
    (let ((epub-reader-store-directory directory)
          (epub-reader-enable-progress nil)
          (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
          (epub-reader-first-paint-max-characters
           epub-reader-chunk-max-characters))
      (setq reader
            (if undisplayed
                (epub-reader-ui-open source)
              (epub-reader-open source)))
      (with-current-buffer reader
        (let* ((block (cl-find "mixed" (epub-reader-ui--current-blocks)
                               :key #'epub-reader-block-element-id
                               :test #'equal))
               (text (substring-no-properties
                      (epub-reader-block-text block)))
               (start-offset (string-match "Emacs" text))
               (end-offset (+ (string-match "EPUB" text) 4))
               (start (epub-reader-note-test--source-position
                       "id:mixed" start-offset))
               (end (1+ (epub-reader-note-test--source-position
                         "id:mixed" (1- end-offset)))))
          (goto-char end)
          (set-mark start)
          (setq mark-active t transient-mark-mode t)
          (setq annotation (epub-reader-add-highlight start end))
          (goto-char start))))
    (list :reader reader :annotation annotation
          :source source :directory directory)))

(defun epub-reader-note-test--cleanup (resources)
  "Release reader and temporary RESOURCES created by the test helper."
  (let ((reader (plist-get resources :reader))
        (source (plist-get resources :source))
        (directory (plist-get resources :directory)))
    (dolist (editor (epub-reader-note-test--editor-buffers))
      (when (eq (buffer-local-value 'epub-reader-note--source-buffer editor)
                reader)
        (with-current-buffer editor
          (setq-local epub-reader-note--save-function nil)
          (set-buffer-modified-p nil))
        (kill-buffer editor)))
    (when (buffer-live-p reader)
      (with-current-buffer reader
        (setq-local kill-buffer-query-functions nil))
      (kill-buffer reader))
    (when (and source (file-exists-p source))
      (delete-file source))
    (when (and directory (file-directory-p directory))
      (delete-directory directory t))))

(defun epub-reader-note-test--edit (resources)
  "Open RESOURCES' annotation editor from its reader window."
  (let* ((reader (plist-get resources :reader))
         (annotation (plist-get resources :annotation))
         (reader-window (get-buffer-window reader t)))
    (select-window reader-window)
    (with-current-buffer reader
      (epub-reader-ui--edit-annotation-note reader annotation))))

(ert-deftest epub-reader-note-fit-height-caps-short-targets ()
  (should (= (epub-reader-note--fit-window-height 13 8 4) 6))
  (should (= (epub-reader-note--fit-window-height 6 8 4) 4))
  (should (= (epub-reader-note--fit-window-height 25 8 4) 8))
  (should (= (epub-reader-note--fit-window-height 13 5 4) 5)))

(ert-deftest epub-reader-note-editor-ret-saves-multiline-plain-text ()
  (let (editor saved)
    (unwind-protect
        (progn
          (setq editor
                (epub-reader-note-edit
                 "Existing note" (lambda (note) (setq saved note))))
          (with-current-buffer editor
            (should (derived-mode-p 'epub-reader-note-mode))
            (should-not buffer-read-only)
            (should (equal (buffer-string) "Existing note"))
            (should (eq (key-binding (kbd "RET")) #'newline))
            (should (eq (key-binding (kbd "C-c C-c"))
                        #'epub-reader-note-save))
            (should (eq (key-binding (kbd "C-c C-k"))
                        #'epub-reader-note-discard))
            (call-interactively (key-binding (kbd "RET")))
            (insert "Second line")
            (call-interactively (key-binding (kbd "C-c C-c"))))
          (should-not (buffer-live-p editor))
          (should (equal saved "Existing note\nSecond line")))
      (when (buffer-live-p editor) (kill-buffer editor)))))

(ert-deftest epub-reader-note-editor-discard-does-not-save ()
  (let ((saved 'unchanged)
        editor)
    (unwind-protect
        (progn
          (setq editor
                (epub-reader-note-edit
                 "Original" (lambda (note) (setq saved note))))
          (with-current-buffer editor
            (goto-char (point-max))
            (insert " changed")
            (call-interactively (key-binding (kbd "C-c C-k"))))
          (should-not (buffer-live-p editor))
          (should (eq saved 'unchanged)))
      (when (buffer-live-p editor) (kill-buffer editor)))))

(ert-deftest epub-reader-note-editor-closes-when-source-dies ()
  (let ((source (generate-new-buffer " *epub-note-source*"))
        (saved 'unchanged)
        editor)
    (unwind-protect
        (progn
          (setq editor
                (epub-reader-note-edit
                 "Original" (lambda (note) (setq saved note)) source))
          (with-current-buffer editor (insert " changed"))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _ignored) t)))
            (kill-buffer source))
          (should-not (buffer-live-p editor))
          (should (eq saved 'unchanged)))
      (when (buffer-live-p editor) (kill-buffer editor))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest epub-reader-note-multiline-round-trip-and-list-wrap ()
  (let ((directory (make-temp-file "epub-reader-notes-" t))
        (source (make-temp-file "epub-reader-note-book-" nil ".epub"))
        (epub-reader-enable-progress nil)
        (epub-reader-first-paint-max-blocks epub-reader-chunk-max-blocks)
        (epub-reader-first-paint-max-characters
         epub-reader-chunk-max-characters)
        (first-note
         (concat
          "First multiline note keeps every word visible even when the "
          "annotations window is narrow.\n"
          "Second line survives with the final marker."))
        (saved-note
         (concat
          "Replacement note has a deliberately long first line that must "
          "wrap without losing its final words.\n"
          "The second line also survives the sidecar round trip."))
        reader list-buffer editor annotation-id)
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
                   (start (epub-reader-note-test--source-position
                           "id:mixed" start-offset))
                   (end (1+ (epub-reader-note-test--source-position
                             "id:mixed" (1- end-offset)))))
              (goto-char end)
              (set-mark start)
              (setq mark-active t transient-mark-mode t)
              (epub-reader-add-highlight start end)
              (goto-char start)
              (setq editor (epub-reader-edit-note))))
          (with-current-buffer editor
            (erase-buffer)
            (insert first-note)
            (epub-reader-note-save))
          (setq editor nil)
          (with-current-buffer reader
            (let ((annotation
                   (car (epub-reader-session-annotations
                         epub-reader-ui--session))))
              (setq annotation-id (epub-reader-annotation-id annotation))
              (should (equal (epub-reader-annotation-note annotation)
                             first-note)))
            (setq list-buffer
                  (cl-letf (((symbol-function 'textui--visible-width)
                             (lambda (_buffer) 28)))
                    (epub-reader-annotations))))
          (with-current-buffer list-buffer
            (should truncate-lines)
            (dolist (word '("First" "narrow" "Second" "marker"))
              (goto-char (point-min))
              (should (search-forward word nil t)))
            (should (> (epub-reader-note-test--annotation-line-count
                        annotation-id)
                       4))
            (goto-char (epub-reader-note-test--annotation-position))
            (setq editor (epub-reader-annotation-list-edit-note)))
          ;; The list is only the launch point; the reader owns persistence.
          (kill-buffer list-buffer)
          (setq list-buffer nil)
          (with-current-buffer editor
            (should (equal (buffer-string) first-note))
            (erase-buffer)
            (insert saved-note)
            (epub-reader-note-save))
          (setq editor nil)
          (with-current-buffer reader
            (should (equal
                     (epub-reader-annotation-note
                      (car (epub-reader-session-annotations
                            epub-reader-ui--session)))
                     saved-note)))
          (kill-buffer reader)
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (let ((annotation
                   (car (epub-reader-session-annotations
                         epub-reader-ui--session))))
              (should annotation)
              (should (equal (epub-reader-annotation-id annotation)
                             annotation-id))
              (should (equal (epub-reader-annotation-note annotation)
                             saved-note)))
            (setq list-buffer
                  (cl-letf (((symbol-function 'textui--visible-width)
                             (lambda (_buffer) 28)))
                    (epub-reader-annotations))))
          (with-current-buffer list-buffer
            (dolist (word '("Replacement" "words" "second" "trip"))
              (goto-char (point-min))
              (should (search-forward word nil t)))
            (should (> (epub-reader-note-test--annotation-line-count
                        annotation-id)
                       5))))
      (when (buffer-live-p editor) (kill-buffer editor))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (when (buffer-live-p reader) (kill-buffer reader))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-note-editor-opens-below-reader-without-touching-panels ()
  (let ((epub-reader-open-full-frame t)
        resources toc annotations editor)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources (epub-reader-note-test--open-annotated-reader))
            (let ((reader (plist-get resources :reader)))
              (with-current-buffer reader
                (setq toc (epub-reader-toc)))
              (select-window (get-buffer-window reader t))
              (with-current-buffer reader
                (setq annotations (epub-reader-annotations)))
              (let ((reader-window (get-buffer-window reader t))
                    (toc-window (get-buffer-window toc t))
                    (annotations-window (get-buffer-window annotations t))
                    (group (with-current-buffer reader
                             epub-reader-ui--layout-group))
                    (window-count (length (window-list nil 'no-minibuffer))))
                (let ((reader-height (window-total-height reader-window)))
                  (should (eq annotations toc))
                  (should (eq toc-window annotations-window))
                (setq editor (epub-reader-note-test--edit resources))
                (let ((editor-window (get-buffer-window editor t)))
                  (should (window-live-p reader-window))
                  (should (window-live-p annotations-window))
                  (should (eq (window-buffer reader-window) reader))
                  (should (eq (window-buffer annotations-window) annotations))
                  (should (eq (window-in-direction 'above editor-window)
                              reader-window))
                  (should (= (window-total-height editor-window)
                             epub-reader-note-window-height))
                  (should (< (window-total-height reader-window)
                             reader-height))
                  (should (epub-reader-layout-live-p group))
                  (should-not
                   (window-parameter
                    editor-window epub-reader-layout--window-parameter))
                  (with-current-buffer editor
                    (epub-reader-note-discard))
                  (setq editor nil)
                  (should (= (length (window-list nil 'no-minibuffer))
                             window-count))
                  (should (= (window-total-height reader-window)
                             reader-height))
                  (should (eq (selected-window) reader-window)))))))
        (epub-reader-note-test--cleanup resources)))))

(ert-deftest epub-reader-note-save-closes-editor-and-returns-focus ()
  (let ((epub-reader-open-full-frame t)
        resources editor)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources (epub-reader-note-test--open-annotated-reader))
            (let* ((reader (plist-get resources :reader))
                   (annotation (plist-get resources :annotation))
                   (reader-window (get-buffer-window reader t))
                   (window-count (length (window-list nil 'no-minibuffer))))
              (setq editor (epub-reader-note-test--edit resources))
              (with-current-buffer editor
                (erase-buffer)
                (insert "Saved from the editor")
                (call-interactively (key-binding (kbd "C-c C-c"))))
              (should-not (buffer-live-p editor))
              (should (= (length (window-list nil 'no-minibuffer))
                         window-count))
              (should (eq (selected-window) reader-window))
              (should (equal (epub-reader-annotation-note annotation)
                             "Saved from the editor"))))
        (epub-reader-note-test--cleanup resources)))))

(ert-deftest epub-reader-note-discard-returns-focus-to-annotation-list ()
  (let ((epub-reader-open-full-frame t)
        resources annotations editor)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources (epub-reader-note-test--open-annotated-reader))
            (let* ((reader (plist-get resources :reader))
                   (annotation (plist-get resources :annotation)))
              (with-current-buffer reader
                (setq annotations (epub-reader-annotations)))
              (let ((list-window (get-buffer-window annotations t)))
                (with-current-buffer annotations
                  (goto-char (epub-reader-note-test--annotation-position))
                  (setq editor (epub-reader-annotation-list-edit-note)))
                (with-current-buffer editor
                  (goto-char (point-max))
                  (insert " discarded")
                  (call-interactively (key-binding (kbd "C-c C-k"))))
                (should-not (buffer-live-p editor))
                (should (eq (selected-window) list-window))
                (should (string-empty-p
                         (epub-reader-annotation-note annotation))))))
        (epub-reader-note-test--cleanup resources)))))

(ert-deftest epub-reader-note-editor-never-takes-second-reader-window ()
  (let ((epub-reader-open-full-frame nil)
        resources-a resources-b editor)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources-a
                  (epub-reader-note-test--open-annotated-reader t)
                  resources-b
                  (epub-reader-note-test--open-annotated-reader t))
            (let* ((reader-a (plist-get resources-a :reader))
                   (reader-b (plist-get resources-b :reader))
                   (reader-a-window (selected-window))
                   (reader-b-window (split-window-right)))
              (set-window-buffer reader-a-window reader-a)
              (set-window-buffer reader-b-window reader-b)
              (select-window reader-a-window)
              (with-current-buffer reader-a
                (epub-reader-ui--ensure-layout reader-a))
              (select-window reader-b-window)
              (let ((group-b
                     (with-current-buffer reader-b
                       (epub-reader-ui--ensure-layout reader-b))))
                (select-window reader-a-window)
                (setq editor (epub-reader-note-test--edit resources-a))
                (let ((editor-window (get-buffer-window editor t)))
                  (should (eq (window-buffer reader-b-window) reader-b))
                  (should (epub-reader-layout-live-p group-b))
                  (should (eq (epub-reader-layout-window group-b 'reader)
                              reader-b-window))
                  (should (= (car (window-edges editor-window))
                             (car (window-edges reader-a-window))))
                  (should (= (nth 2 (window-edges editor-window))
                             (nth 2 (window-edges reader-a-window))))))))
        (epub-reader-note-test--cleanup resources-a)
        (epub-reader-note-test--cleanup resources-b)))))

(ert-deftest epub-reader-note-short-reader-uses-main-window-split ()
  (let ((epub-reader-open-full-frame nil)
        (user-buffer (generate-new-buffer " *epub-note-user*"))
        resources editor)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources
                  (epub-reader-note-test--open-annotated-reader t))
            (let* ((reader (plist-get resources :reader))
                   (reader-window (selected-window))
                   user-window)
              (set-window-buffer reader-window reader)
              (with-current-buffer reader
                (epub-reader-ui--ensure-layout reader))
              (setq user-window (split-window-below 6))
              (set-window-buffer user-window user-buffer)
              (select-window reader-window)
              (let ((reader-height (window-total-height reader-window))
                    (user-height (window-total-height user-window))
                    (window-count (length (window-list nil 'no-minibuffer))))
                (should (= reader-height 6))
                (setq editor (epub-reader-note-test--edit resources))
                (let ((editor-window (get-buffer-window editor t)))
                  (should (= (window-total-height editor-window) 4))
                  (should (>= (window-total-height reader-window)
                              reader-height))
                  (should (eq (window-buffer reader-window) reader))
                  (should (get-buffer-window user-buffer t))
                  (with-current-buffer editor
                    (epub-reader-note-discard))
                  (setq editor nil)
                  (should (= (length (window-list nil 'no-minibuffer))
                             window-count))
                  (should (= (window-total-height reader-window)
                             reader-height))
                  (should (= (window-total-height user-window) user-height))
                  (should (eq (selected-window) reader-window))))))
        (epub-reader-note-test--cleanup resources)
        (when (buffer-live-p user-buffer) (kill-buffer user-buffer))))))

(ert-deftest epub-reader-note-source-killed-discards-with-message ()
  (let ((source (generate-new-buffer " *epub-note-source-message*"))
        editor messages)
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) source)
      (unwind-protect
          (progn
            (setq editor
                  (epub-reader-note-edit
                   "Original" #'ignore source (selected-window) "message"))
            (with-current-buffer editor (insert " changed"))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _ignored) t))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
              (kill-buffer source))
            (should-not (buffer-live-p editor))
            (should (cl-some
                     (lambda (text)
                       (string-match-p "discard" (downcase text)))
                     messages)))
        (when (buffer-live-p editor)
          (with-current-buffer editor (set-buffer-modified-p nil))
          (kill-buffer editor))
        (when (buffer-live-p source)
          (with-current-buffer source
            (setq-local kill-buffer-query-functions nil))
          (kill-buffer source))))))

(ert-deftest epub-reader-note-unsaved-asks-before-reader-is-killed ()
  (let ((epub-reader-open-full-frame nil)
        resources editor asked)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources (epub-reader-note-test--open-annotated-reader))
            (let* ((reader (plist-get resources :reader))
                   (reader-window (get-buffer-window reader t))
                   (group (with-current-buffer reader
                            epub-reader-ui--layout-group)))
              (setq editor (epub-reader-note-test--edit resources))
              (with-current-buffer editor (insert " unsaved"))
              (should-not
               (cl-letf (((symbol-function 'yes-or-no-p)
                          (lambda (&rest _ignored)
                            (setq asked t)
                            nil)))
                 (kill-buffer reader)))
              (should asked)
              (should (buffer-live-p reader))
              (should (buffer-live-p editor))
              (should (window-live-p reader-window))
              (should (eq (window-buffer reader-window) reader))
              (should (get-buffer-window editor t))
              (should (epub-reader-layout-live-p group))
              (should
               (cl-letf (((symbol-function 'yes-or-no-p)
                          (lambda (&rest _ignored) t)))
                 (kill-buffer reader)))
              (should-not (buffer-live-p reader))
              (should-not (buffer-live-p editor))))
        (epub-reader-note-test--cleanup resources)))))

(ert-deftest epub-reader-note-same-annotation-reuses-editor ()
  (let ((epub-reader-open-full-frame t)
        resources first second)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq resources (epub-reader-note-test--open-annotated-reader))
            (setq first (epub-reader-note-test--edit resources))
            (select-window
             (get-buffer-window (plist-get resources :reader) t))
            (setq second (epub-reader-note-test--edit resources))
            (should (eq first second))
            (should (= (length (epub-reader-note-test--editor-buffers)) 1))
            (should (eq (selected-window) (get-buffer-window first t)))
            (should-not (get-buffer "*EPUB Note*<2>")))
        (epub-reader-note-test--cleanup resources)))))

(ert-deftest epub-reader-note-save-error-keeps-editor ()
  (let (editor)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq editor
                  (epub-reader-note-edit
                   "Recover me"
                   (lambda (_note) (error "Injected note save failure"))))
            (with-current-buffer editor
              (goto-char (point-max))
              (insert " after failure")
              (should-error (epub-reader-note-save)
                            :type 'error)
              (should (buffer-live-p editor))
              (should (buffer-modified-p))
              (should (equal (buffer-string)
                             "Recover me after failure")))
            (should (get-buffer-window editor t)))
        (when (buffer-live-p editor)
          (with-current-buffer editor (set-buffer-modified-p nil))
          (kill-buffer editor))))))

(provide 'epub-reader-note-test)
;;; epub-reader-note-test.el ends here
