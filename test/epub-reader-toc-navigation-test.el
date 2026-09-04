;;; epub-reader-toc-navigation-test.el --- TOC navigation tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-test-helper)

(defun epub-reader-toc-navigation-test--invoke (map key)
  "Interactively invoke KEY's command from MAP."
  (call-interactively (lookup-key map (kbd key))))

(defun epub-reader-toc-navigation-test--assert-current
    (reader toc-window index key)
  "Assert READER is at INDEX and TOC-WINDOW marks row KEY under point."
  (should (eq (selected-window) toc-window))
  (should (eq (window-buffer toc-window) (current-buffer)))
  (with-current-buffer reader
    (should (= (plist-get textui-state :spine-index) index)))
  (let ((row (epub-reader-toc--row-at-point)))
    (should row)
    (should (epub-reader-toc-row-current-p row))
    (should (equal (epub-reader-toc-row-key row) key))
    (should (= (point) (window-point toc-window)))
    (should (eq (get-text-property (point) 'face)
                'epub-reader-toc-current-face))))

(ert-deftest epub-reader-toc-navigation-keymaps-preserve-distinct-actions ()
  (dolist (binding `(("n" . ,#'epub-reader-toc-next-chapter)
                     ("]" . ,#'epub-reader-toc-next-chapter)
                     ("p" . ,#'epub-reader-toc-previous-chapter)
                     ("[" . ,#'epub-reader-toc-previous-chapter)
                     ("t" . ,#'epub-reader-toc-quit)
                     ("q" . ,#'epub-reader-toc-quit)
                     ("TAB" . ,#'epub-reader-toc-toggle)))
    (should (eq (lookup-key epub-reader-toc-mode-map (kbd (car binding)))
                (cdr binding))))
  (should (eq (lookup-key epub-reader-ui-mode-map (kbd "t"))
              #'epub-reader-toc))
  (should (eq (lookup-key epub-reader-ui-mode-map (kbd "a"))
              #'epub-reader-annotations))
  (dolist (binding `(("n" . ,#'epub-reader-annotation-list-next)
                     ("p" . ,#'epub-reader-annotation-list-previous)
                     ("a" . ,#'epub-reader-annotation-list-quit)
                     ("q" . ,#'epub-reader-annotation-list-quit)))
    (should
     (eq (lookup-key epub-reader-annotation-list-mode-map
                     (kbd (car binding)))
         (cdr binding)))))

(ert-deftest epub-reader-annotation-list-n-and-p-move-between-highlights ()
  (let ((first (epub-reader-annotation--create :id "first"))
        (second (epub-reader-annotation--create :id "second"))
        (third (epub-reader-annotation--create :id "third")))
    (with-temp-buffer
      (insert "Book — Highlights\n\nChapter One\n\n")
      (insert (propertize "First highlight" 'epub-reader-annotation first)
              "   \n"
              (propertize "continued first highlight"
                          'epub-reader-annotation first)
              "\n\n")
      (let ((between (point)))
        (insert "Chapter Two\n\n"
                (propertize "Second highlight"
                            'epub-reader-annotation second)
                "\n"
                (propertize "Note: wrapped second note"
                            'epub-reader-annotation second)
                "\n\n"
                (propertize "Third highlight"
                            'epub-reader-annotation third)
                "\n")
        (goto-char (point-min))
        (epub-reader-annotation-list-next)
        (should (eq (epub-reader-annotation-list--at-point) first))
        (epub-reader-annotation-list-next)
        (should (eq (epub-reader-annotation-list--at-point) second))
        (epub-reader-annotation-list-next)
        (should (eq (epub-reader-annotation-list--at-point) third))
        (let ((position (point)))
          (should-error (epub-reader-annotation-list-next)
                        :type 'user-error)
          (should (= (point) position)))
        (epub-reader-annotation-list-previous)
        (should (eq (epub-reader-annotation-list--at-point) second))
        (epub-reader-annotation-list-previous)
        (should (eq (epub-reader-annotation-list--at-point) first))
        (let ((position (point)))
          (should-error (epub-reader-annotation-list-previous)
                        :type 'user-error)
          (should (= (point) position)))

        ;; Heading rows have no annotation property.  Navigation chooses the
        ;; nearest real highlight in the requested direction.
        (goto-char between)
        (epub-reader-annotation-list-next)
        (should (eq (epub-reader-annotation-list--at-point) second))
        (goto-char between)
        (epub-reader-annotation-list-previous)
        (should (eq (epub-reader-annotation-list--at-point) first))

        ;; TextUI may leave unpropertized padding at the right of a row.  It
        ;; still belongs to the visible highlight on that row.
        (goto-char (point-min))
        (search-forward "First highlight   ")
        (backward-char)
        (should (eq (epub-reader-annotation-list--at-point) first))
        (epub-reader-annotation-list-next)
        (should (eq (epub-reader-annotation-list--at-point) second))))))

(ert-deftest epub-reader-toc-navigation-all-chapter-aliases-track-marker ()
  (let ((epub-reader-open-full-frame t)
        reader toc)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq toc (epub-reader-toc)))
            (let ((toc-window (get-buffer-window toc t)))
              (with-current-buffer toc
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 0 "0")
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "n")
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 1 "1")
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "p")
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 0 "0")
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "]")
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 1 "1")
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "[")
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 0 "0"))))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))))))

(ert-deftest epub-reader-toc-navigation-boundaries-match-reader-and-keep-focus ()
  (let ((epub-reader-open-full-frame t)
        reader toc)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (let (reader-error)
            (setq reader-error
                  (with-current-buffer reader
                    (condition-case error-data
                        (epub-reader-previous-chapter)
                      (user-error error-data))))
            (with-current-buffer reader
              (setq toc (epub-reader-toc)))
            (let ((toc-window (get-buffer-window toc t)))
              (with-current-buffer toc
                (let ((position (point)))
                  (should
                   (equal
                    (condition-case error-data
                        (epub-reader-toc-navigation-test--invoke
                         epub-reader-toc-mode-map "p")
                      (user-error error-data))
                    reader-error))
                  (should (= (point) position))
                  (epub-reader-toc-navigation-test--assert-current
                   reader toc-window 0 "0"))
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "n")
                (let ((position (point)))
                  (setq reader-error
                        (with-current-buffer reader
                          (condition-case error-data
                              (epub-reader-next-chapter)
                            (user-error error-data))))
                  (should
                   (equal
                    (condition-case error-data
                        (epub-reader-toc-navigation-test--invoke
                         epub-reader-toc-mode-map "]")
                      (user-error error-data))
                    reader-error))
                  (should (= (point) position))
                  (epub-reader-toc-navigation-test--assert-current
                   reader toc-window 1 "1")))))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))))))

(ert-deftest epub-reader-toc-navigation-reveals-folded-current-ancestors ()
  (let ((epub-reader-open-full-frame t)
        reader toc)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub3-edge.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (let* ((session (epub-reader-ui--current-session))
                     (publication (epub-reader-session-publication session))
                     (item (aref (epub-reader-publication-spine publication)
                                 0))
                     (weight (aref (epub-reader-session-spine-weights session)
                                   0))
                     (group (car (epub-reader-publication-toc publication))))
                ;; Keep the nested EPUB 3 TOC while giving its one resource two
                ;; spine positions, so both chapter directions exercise the
                ;; real navigation and refresh path.
                (setf (epub-reader-publication-spine publication)
                      (vector item item)
                      (epub-reader-publication-toc publication)
                      (list group group)
                      (epub-reader-session-spine-weights session)
                      (vector weight weight)
                      (epub-reader-session-total-weight session)
                      (* 2 weight)))
              (setq toc (epub-reader-toc)))
            (let ((toc-window (get-buffer-window toc t)))
              (with-current-buffer toc
                (dolist (key '("0/0" "0" "1"))
                  (goto-char (epub-reader-toc--key-position key))
                  (set-window-point toc-window (point))
                  (epub-reader-toc-navigation-test--invoke
                   epub-reader-toc-mode-map "TAB"))
                (should (equal (plist-get textui-state :collapsed)
                               '("1" "0" "0/0")))
                (let ((position (point))
                      (window-position (window-point toc-window))
                      (collapsed (copy-sequence
                                  (plist-get textui-state :collapsed))))
                  (should-error
                   (epub-reader-toc-navigation-test--invoke
                    epub-reader-toc-mode-map "p")
                   :type 'user-error)
                  (should (= (point) position))
                  (should (= (window-point toc-window) window-position))
                  (should (equal (plist-get textui-state :collapsed)
                                 collapsed)))
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "n")
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 1 "0/0")
                (should-not (member "0" (plist-get textui-state :collapsed)))
                (should (member "0/0" (plist-get textui-state :collapsed)))
                (should (member "1" (plist-get textui-state :collapsed)))
                (goto-char (epub-reader-toc--key-position "0"))
                (set-window-point toc-window (point))
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "TAB")
                (should (member "0" (plist-get textui-state :collapsed)))
                (epub-reader-toc-navigation-test--invoke
                 epub-reader-toc-mode-map "p")
                (epub-reader-toc-navigation-test--assert-current
                 reader toc-window 0 "0/0")
                (should-not (member "0" (plist-get textui-state :collapsed)))
                (should (member "0/0" (plist-get textui-state :collapsed)))
                (should (member "1" (plist-get textui-state :collapsed)))
                (let ((position (point))
                      (window-position (window-point toc-window))
                      (collapsed (copy-sequence
                                  (plist-get textui-state :collapsed))))
                  (should-error
                   (epub-reader-toc-navigation-test--invoke
                    epub-reader-toc-mode-map "[")
                   :type 'user-error)
                  (should (= (point) position))
                  (should (= (window-point toc-window) window-position))
                  (should (equal (plist-get textui-state :collapsed)
                                 collapsed))))))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))))))

(ert-deftest epub-reader-toc-navigation-allows-chapter-without-toc-entry ()
  (let ((epub-reader-open-full-frame t)
        reader toc)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (let* ((session (epub-reader-ui--current-session))
                     (publication (epub-reader-session-publication session)))
                (setf (epub-reader-publication-toc publication)
                      (list (car (epub-reader-publication-toc publication)))))
              (setq toc (epub-reader-toc)))
            (let ((toc-window (get-buffer-window toc t)))
              (with-current-buffer toc
                (let ((position (point))
                      (window-position (window-point toc-window))
                      (collapsed (copy-sequence
                                  (plist-get textui-state :collapsed))))
                  (epub-reader-toc-navigation-test--invoke
                   epub-reader-toc-mode-map "n")
                  (should (eq (selected-window) toc-window))
                  (with-current-buffer reader
                    (should (= (plist-get textui-state :spine-index) 1)))
                  (should-not (epub-reader-toc--current-position))
                  (should-not (epub-reader-toc--key-position "1"))
                  (should (= (point) position))
                  (should (= (window-point toc-window) window-position))
                  (should (equal (plist-get textui-state :collapsed)
                                 collapsed))))))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))))))

(ert-deftest epub-reader-toc-navigation-t-and-a-focus-open-or-close ()
  (let ((epub-reader-open-full-frame t)
        reader toc annotations)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (epub-reader-toc-navigation-test--invoke
             epub-reader-ui-mode-map "t")
            (setq toc (window-buffer (selected-window)))
            (let ((toc-window (selected-window)))
              (should epub-reader-toc-mode)
              (with-current-buffer reader
                (let ((panel
                       (epub-reader-session-panel
                        epub-reader-ui--session)))
                  (should (epub-reader-panel-live-p panel))
                  (should (eq
                           (epub-reader-panel--handle-child-frame-side panel)
                           'right))))
              (select-window (get-buffer-window reader t))
              (epub-reader-toc-navigation-test--invoke
               epub-reader-ui-mode-map "t")
              (should (eq (selected-window) toc-window))
              (should (eq (window-buffer toc-window) toc))
              (epub-reader-toc-navigation-test--invoke
               epub-reader-toc-mode-map "t")
              (should-not (get-buffer-window toc t))
              (should (eq (window-buffer (selected-window)) reader)))
            (epub-reader-toc-navigation-test--invoke
             epub-reader-ui-mode-map "a")
            (setq annotations (window-buffer (selected-window)))
            (let ((annotations-window (selected-window)))
              (should epub-reader-annotation-list-mode)
              (select-window (get-buffer-window reader t))
              (epub-reader-toc-navigation-test--invoke
               epub-reader-ui-mode-map "a")
              (should (eq (selected-window) annotations-window))
              (should (eq (window-buffer annotations-window) annotations))
              (epub-reader-toc-navigation-test--invoke
               epub-reader-annotation-list-mode-map "a")
              (should-not (get-buffer-window annotations t))
              (should (eq (window-buffer (selected-window)) reader))))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))
        (when (buffer-live-p annotations) (kill-buffer annotations))))))

(defun epub-reader-toc-navigation-test--panel-view (buffer)
  "Return the view BUFFER's panel currently shows."
  (plist-get (buffer-local-value 'textui-state buffer) :view))

(defun epub-reader-toc-navigation-test--tab-widgets (buffer)
  "Return the tab widgets on BUFFER's first line, in buffer order."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((limit (line-end-position))
            widgets)
        (while (< (point) limit)
          (let ((widget (widget-at (point))))
            (when (and widget (not (memq widget widgets)))
              (push widget widgets)))
          (forward-char 1))
        (nreverse widgets)))))

(ert-deftest epub-reader-panel-one-host-switches-all-reader-views ()
  (let ((epub-reader-open-full-frame t)
        reader session panel-buffer panel)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq session epub-reader-ui--session
                    panel-buffer (epub-reader-toc)
                    panel (epub-reader-session-panel session)))
            (should (epub-reader-panel-live-p panel))
            (should (eq (window-buffer (selected-window)) panel-buffer))
            (with-current-buffer panel-buffer
              (should (eq epub-reader-ui--panel-view-reader reader))
              (should (eq (epub-reader-toc-navigation-test--panel-view
                           panel-buffer)
                          'toc))
              (should epub-reader-toc-mode)
              (should-not epub-reader-annotation-list-mode)
              (should-not header-line-format))

            ;; Selecting a tab re-renders the same buffer in the same host
            ;; instead of creating a second buffer or panel.
            (with-current-buffer panel-buffer
              (should (eq (epub-reader-panel-select-highlights)
                          panel-buffer)))
            (should (eq (epub-reader-session-panel session) panel))
            (should (eq (epub-reader-session-panel-view session)
                        'annotations))
            (should (eq (epub-reader-session-panel-buffer session)
                        panel-buffer))
            (should (eq (window-buffer (selected-window)) panel-buffer))
            (with-current-buffer panel-buffer
              (should (eq (epub-reader-toc-navigation-test--panel-view
                           panel-buffer)
                          'annotations))
              (should epub-reader-annotation-list-mode)
              (should-not epub-reader-toc-mode))

            (with-current-buffer panel-buffer
              (should (eq (epub-reader-panel-select-bookmarks)
                          panel-buffer)))
            (should (eq (epub-reader-session-panel session) panel))
            (should (eq (epub-reader-session-panel-view session)
                        'bookmarks))
            (should (eq (window-buffer (selected-window)) panel-buffer))
            (with-current-buffer panel-buffer
              (should (eq (epub-reader-toc-navigation-test--panel-view
                           panel-buffer)
                          'bookmarks))
              (should epub-reader-bookmark-list-mode)
              (should-not epub-reader-annotation-list-mode))

            (with-current-buffer panel-buffer
              (epub-reader-bookmark-list-quit))
            (should (epub-reader-panel-live-p panel))
            (should-not (epub-reader-panel-visible-p panel))
            (should (eq (window-buffer (selected-window)) reader))

            (with-current-buffer reader
              (should (eq (epub-reader-toc) panel-buffer))
              (should (eq (epub-reader-session-panel session) panel)))
            (should (epub-reader-panel-visible-p panel))
            (should (eq (window-buffer (selected-window)) panel-buffer))
            (should (eq (epub-reader-toc-navigation-test--panel-view
                         panel-buffer)
                        'toc)))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p panel-buffer) (kill-buffer panel-buffer))))))

(ert-deftest epub-reader-panel-tabs-are-widgets-switched-by-mouse-and-keys ()
  (let ((epub-reader-open-full-frame t)
        reader panel-buffer)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq panel-buffer (epub-reader-toc)))
            (let ((tabs (epub-reader-toc-navigation-test--tab-widgets
                         panel-buffer)))
              (should (= (length tabs) 3))
              (should (equal (mapcar (lambda (tab) (widget-get tab :tag))
                                     tabs)
                             '("Contents" "Highlights" "Bookmarks")))
              (should (equal (mapcar (lambda (tab)
                                       (widget-get tab :epub-reader-view))
                                     tabs)
                             '(toc annotations bookmarks)))
              (should (eq (widget-apply (nth 0 tabs) :button-face-get)
                          'epub-reader-panel-active-tab-face))
              (should (eq (widget-apply (nth 1 tabs) :button-face-get)
                          'epub-reader-panel-inactive-tab-face))
              (with-current-buffer panel-buffer
                (should (eq (get-char-property (widget-get (nth 0 tabs) :from)
                                               'face)
                            'epub-reader-panel-active-tab-face))
                (should (get-char-property (widget-get (nth 1 tabs) :from)
                                           'mouse-face)))

              ;; A real mouse click: `widget-button-click' handles the
              ;; button-down event and reads the release itself.
              (let* ((tab (nth 1 tabs))
                     (position (marker-position (widget-get tab :from)))
                     (window (get-buffer-window panel-buffer t))
                     (posn (list window position '(0 . 0) 0))
                     (unread-command-events
                      (list (list 'mouse-1 posn))))
                (with-current-buffer panel-buffer
                  (widget-button-click (list 'down-mouse-1 posn)))))
            (should (eq (epub-reader-toc-navigation-test--panel-view
                         panel-buffer)
                        'annotations))
            (with-current-buffer panel-buffer
              (should epub-reader-annotation-list-mode))
            (let ((tabs (epub-reader-toc-navigation-test--tab-widgets
                         panel-buffer)))
              (should (eq (widget-apply (nth 1 tabs) :button-face-get)
                          'epub-reader-panel-active-tab-face))
              (should (eq (widget-apply (nth 0 tabs) :button-face-get)
                          'epub-reader-panel-inactive-tab-face)))

            ;; RET on a tab presses it.
            (with-current-buffer panel-buffer
              (goto-char (widget-get
                          (nth 2 (epub-reader-toc-navigation-test--tab-widgets
                                  panel-buffer))
                          :from))
              (epub-reader-toc-navigation-test--invoke
               epub-reader-annotation-list-mode-map "RET"))
            (should (eq (epub-reader-toc-navigation-test--panel-view
                         panel-buffer)
                        'bookmarks))

            ;; Number keys switch from every view.
            (with-current-buffer panel-buffer
              (epub-reader-toc-navigation-test--invoke
               epub-reader-bookmark-list-mode-map "1"))
            (should (eq (epub-reader-toc-navigation-test--panel-view
                         panel-buffer)
                        'toc))
            (with-current-buffer panel-buffer
              (epub-reader-toc-navigation-test--invoke
               epub-reader-toc-mode-map "2"))
            (should (eq (epub-reader-toc-navigation-test--panel-view
                         panel-buffer)
                        'annotations))
            (with-current-buffer panel-buffer
              (epub-reader-toc-navigation-test--invoke
               epub-reader-annotation-list-mode-map "3"))
            (should (eq (epub-reader-toc-navigation-test--panel-view
                         panel-buffer)
                        'bookmarks))
            (should (eq (window-buffer (selected-window)) panel-buffer)))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p panel-buffer) (kill-buffer panel-buffer))))))

(ert-deftest epub-reader-toc-orphan-quit-and-navigation-restore-reader ()
  (let ((epub-reader-open-full-frame t)
        (escape (generate-new-buffer " *epub-reader-toc-orphan-escape*"))
        reader toc old-group toc-window)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq toc (epub-reader-toc)
                    old-group epub-reader-ui--layout-group))
            (select-window (get-buffer-window reader t))
            (switch-to-buffer escape)
            (should-not (epub-reader-layout-live-p old-group))
            (should (buffer-live-p reader))
            (should (buffer-live-p toc))

            ;; A dead group cannot identify this newly displayed TOC window.
            (switch-to-buffer toc)
            (setq toc-window (selected-window))
            (with-current-buffer toc
              (epub-reader-toc-quit))
            (should-not (get-buffer-window toc t))

            (switch-to-buffer toc)
            (setq toc-window (selected-window))
            (with-current-buffer toc
              (epub-reader-toc-navigation-test--invoke
               epub-reader-toc-mode-map "n"))
            (should (eq (selected-window) toc-window))
            (should (get-buffer-window reader (selected-frame)))
            (with-current-buffer reader
              (should (= (plist-get textui-state :spine-index) 1))
              (let ((group epub-reader-ui--layout-group))
                (should (epub-reader-layout-live-p group))
                (should (eq (epub-reader-layout-window group 'panel)
                            toc-window))))

            (with-current-buffer toc
              (epub-reader-toc-navigation-test--invoke
               epub-reader-toc-mode-map "RET"))
            (should (eq (window-buffer (selected-window)) reader))
            (select-window toc-window)
            (with-current-buffer toc
              (epub-reader-toc-quit))
            (should-not (get-buffer-window toc t)))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))
        (when (buffer-live-p escape) (kill-buffer escape))))))

(ert-deftest epub-reader-toc-orphan-restore-does-not-take-other-reader-window ()
  (let ((epub-reader-open-full-frame nil)
        (escape (generate-new-buffer "*epub-reader-toc-safe-escape*"))
        (user-buffer (generate-new-buffer "*epub-reader-toc-safe-user*"))
        reader-a reader-b toc-a group-a group-b
        toc-window reader-b-window user-window)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq reader-a
                  (epub-reader-ui-open
                   (epub-reader-test-fixture "epub2.epub"))
                  reader-b
                  (epub-reader-ui-open
                   (epub-reader-test-fixture "epub3.epub")))
            (delete-other-windows)
            (let ((reader-a-window (selected-window)))
              (setq reader-b-window (split-window-right)
                    user-window (split-window-below nil reader-b-window))
              (set-window-buffer reader-a-window reader-a)
              (set-window-buffer reader-b-window reader-b)
              (set-window-buffer user-window user-buffer)
              (select-window reader-b-window)
              (with-current-buffer reader-b
                (setq group-b (epub-reader-ui--ensure-layout reader-b)))
              (select-window reader-a-window)
              (with-current-buffer reader-a
                (setq group-a (epub-reader-ui--ensure-layout reader-a)
                      toc-a (epub-reader-toc)))
              (select-window reader-a-window)
              (switch-to-buffer escape)
              (should-not (epub-reader-layout-live-p group-a))

              ;; Make B least recently used; the unfiltered implementation
              ;; chooses it even though USER-WINDOW is safe.
              (select-window reader-b-window)
              (select-window user-window)
              (select-window reader-a-window)
              (switch-to-buffer toc-a)
              (setq toc-window (selected-window))
              (with-current-buffer toc-a
                (epub-reader-toc-next-chapter))

              (should (eq (selected-window) toc-window))
              (should (eq (window-buffer reader-b-window) reader-b))
              (should (eq (window-buffer user-window) reader-a))
              (should (epub-reader-layout-live-p group-b))
              (should (eq (epub-reader-layout-window group-b 'reader)
                          reader-b-window))
              (with-current-buffer toc-a
                (epub-reader-toc-activate))
              (should (eq (window-buffer reader-b-window) reader-b))
              (should (epub-reader-layout-live-p group-b))))
        (dolist (reader (list reader-a reader-b))
          (when (buffer-live-p reader) (kill-buffer reader)))
        (dolist (buffer (list toc-a escape user-buffer))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest epub-reader-toc-restore-does-not-duplicate-managed-role ()
  (let ((epub-reader-open-full-frame t)
        reader toc group managed-toc-window duplicate-window)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq toc (epub-reader-toc)))
            (setq group
                  (with-current-buffer reader
                    epub-reader-ui--layout-group))
            (setq managed-toc-window (get-buffer-window toc t))
            (select-window (epub-reader-layout-window group 'reader))
            (setq duplicate-window (split-window-below))
            (set-window-buffer duplicate-window toc)
            (select-window duplicate-window)
            (with-current-buffer toc
              (epub-reader-toc-next-chapter))
            (should (eq (selected-window) duplicate-window))
            (should (eq (epub-reader-layout-window group 'panel)
                        managed-toc-window))
            (should-not
             (window-parameter
              duplicate-window epub-reader-layout--window-parameter)))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))))))

(provide 'epub-reader-toc-navigation-test)
;;; epub-reader-toc-navigation-test.el ends here
