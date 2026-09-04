;;; epub-reader-layout-test.el --- Managed reader window tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-test-helper)

(defun epub-reader-layout-test--buffer (name)
  "Return a fresh hidden test buffer named with NAME."
  (generate-new-buffer (format " *epub-reader-layout-%s*" name)))

(defun epub-reader-layout-test--hook-installed-p (hook)
  "Return non-nil when layout change detection is registered on HOOK."
  (memq #'epub-reader-layout--check-windows (default-value hook)))

(defun epub-reader-layout-test--switch-away (role)
  "Assert session-local teardown after switching away from managed ROLE."
  (save-window-excursion
    (delete-other-windows)
    (let* ((main-a (epub-reader-layout-test--buffer "main-a"))
           (toc-a (epub-reader-layout-test--buffer "toc-a"))
           (annotations-a
            (epub-reader-layout-test--buffer "annotations-a"))
           (main-b (epub-reader-layout-test--buffer "main-b"))
           (unrelated (epub-reader-layout-test--buffer "unrelated"))
           (escape (epub-reader-layout-test--buffer "escape"))
           (buffers
            (list main-a toc-a annotations-a main-b unrelated escape))
           (main-a-window (selected-window))
           (main-b-window (split-window-right))
           (unrelated-window (split-window-below nil main-b-window))
           group-a group-b toc-window annotation-window target)
      (unwind-protect
          (progn
            (set-window-buffer main-a-window main-a)
            (set-window-buffer main-b-window main-b)
            (set-window-buffer unrelated-window unrelated)
            (setq group-a
                  (epub-reader-layout-create main-a (selected-frame))
                  group-b
                  (epub-reader-layout-create main-b (selected-frame)))
            (epub-reader-layout-manage-window
             group-a main-a-window main-a 'reader)
            (epub-reader-layout-manage-window
             group-b main-b-window main-b 'reader)
            (setq toc-window
                  (epub-reader-layout-display-side-buffer
                   group-a toc-a 'toc 'left 0 18)
                  annotation-window
                  (epub-reader-layout-display-side-buffer
                   group-a annotations-a 'annotations 'right 0 18)
                  target
                  (pcase role
                    ('reader main-a-window)
                    ('toc toc-window)
                    ('annotations annotation-window)))
            (select-window target)
            (switch-to-buffer escape)

            (should (eq (selected-window) target))
            (should (eq (window-buffer target) escape))
            (should-not (window-parameter
                         target epub-reader-layout--window-parameter))
            (when (memq role '(toc annotations))
              (should-not (window-parameter target 'window-side)))
            (dolist (managed-role '(reader toc annotations))
              (should-not (epub-reader-layout-window
                           group-a managed-role)))

            (should-not (epub-reader-layout-live-p group-a))
            (should-not (memq group-a epub-reader-layout--groups))

            ;; The other session and unrelated user split are not collateral.
            (should (epub-reader-layout-live-p group-b))
            (should (memq group-b epub-reader-layout--groups))
            (should (epub-reader-layout-test--hook-installed-p
                     'buffer-list-update-hook))
            (should (epub-reader-layout-test--hook-installed-p
                     'window-configuration-change-hook))
            (should (window-live-p main-b-window))
            (should (eq (window-buffer main-b-window) main-b))
            (should (eq (epub-reader-layout-window group-b 'reader)
                        main-b-window))
            (should (window-live-p unrelated-window))
            (should (eq (window-buffer unrelated-window) unrelated))
            (should (buffer-live-p main-a)))
        (when (epub-reader-layout-live-p group-a)
          (epub-reader-layout-release group-a))
        (when (epub-reader-layout-live-p group-b)
          (epub-reader-layout-release group-b))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest epub-reader-layout-switch-away-from-main-closes-session-windows ()
  (epub-reader-layout-test--switch-away 'reader))

(ert-deftest epub-reader-layout-switch-away-from-toc-promotes-new-buffer ()
  (epub-reader-layout-test--switch-away 'toc))

(ert-deftest epub-reader-layout-switch-away-from-annotations-promotes-new-buffer ()
  (epub-reader-layout-test--switch-away 'annotations))

(ert-deftest epub-reader-layout-switch-away-releases-last-group-and-can-reopen ()
  (let ((epub-reader-open-full-frame t)
        (escape (epub-reader-layout-test--buffer "escape"))
        reader toc old-group new-group)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq reader
                  (epub-reader-open
                   (epub-reader-test-fixture "epub2.epub"))
                  old-group
                  (with-current-buffer reader
                    epub-reader-ui--layout-group))
            (should (epub-reader-layout-live-p old-group))
            (should (epub-reader-layout-test--hook-installed-p
                     'buffer-list-update-hook))
            (should (epub-reader-layout-test--hook-installed-p
                     'window-configuration-change-hook))

            (switch-to-buffer escape)

            (should-not (epub-reader-layout-live-p old-group))
            (should-not (memq old-group epub-reader-layout--groups))
            (should-not epub-reader-layout--groups)
            (should-not (epub-reader-layout-test--hook-installed-p
                         'buffer-list-update-hook))
            (should-not (epub-reader-layout-test--hook-installed-p
                         'window-configuration-change-hook))
            (should (buffer-live-p reader))
            (should-not (get-buffer-window reader t))

            (switch-to-buffer reader)
            (setq toc (epub-reader-toc)
                  new-group
                  (with-current-buffer reader
                    epub-reader-ui--layout-group))
            (should (epub-reader-layout-live-p new-group))
            (should-not (eq new-group old-group))
            (should (memq new-group epub-reader-layout--groups))
            (should (epub-reader-layout-test--hook-installed-p
                     'buffer-list-update-hook))
            (should (epub-reader-layout-test--hook-installed-p
                     'window-configuration-change-hook)))
        (when (buffer-live-p reader)
          (kill-buffer reader))
        (when (buffer-live-p toc)
          (kill-buffer toc))
        (when (buffer-live-p escape)
          (kill-buffer escape))))))

(ert-deftest epub-reader-layout-focus-or-open-selects-associated-window ()
  (let ((epub-reader-open-full-frame t)
        reader toc annotations bookmarks)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq toc (epub-reader-toc)))
            (let ((toc-window (get-buffer-window toc t)))
              (should (eq (selected-window) toc-window))
              (should (eq (window-parameter toc-window 'window-side) 'right))
              (select-window (get-buffer-window reader t))
              (with-current-buffer reader
                (should (eq (epub-reader-toc) toc)))
              (should (eq (selected-window) toc-window))
              (with-current-buffer toc
                (epub-reader-toc-quit))
              (should-not (get-buffer-window toc t))
              (should (eq (window-buffer (selected-window)) reader)))

            (with-current-buffer reader
              (setq annotations (epub-reader-annotations)))
            (let ((annotation-window (get-buffer-window annotations t)))
              (should (eq annotations toc))
              (should (eq (plist-get (buffer-local-value 'textui-state toc)
                                     :view)
                          'annotations))
              (should (eq (selected-window) annotation-window))
              (should (eq (window-parameter annotation-window 'window-side)
                          'right))
              (select-window (get-buffer-window reader t))
              (with-current-buffer reader
                (should (eq (epub-reader-annotations) annotations)))
              (should (eq (selected-window) annotation-window)))

            (select-window (get-buffer-window reader t))
            (with-current-buffer reader
              (setq bookmarks (epub-reader-bookmarks)))
            (let ((bookmark-window (get-buffer-window bookmarks t)))
              (should (eq bookmarks toc))
              (should (eq (plist-get (buffer-local-value 'textui-state toc)
                                     :view)
                          'bookmarks))
              (should (eq (selected-window) bookmark-window))
              (should (eq (window-parameter bookmark-window 'window-side)
                          'right))))
        (when (buffer-live-p reader)
          (kill-buffer reader))))))

(ert-deftest epub-reader-layout-display-error-restores-managed-group ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((reader (epub-reader-layout-test--buffer "rollback-reader"))
           (side (epub-reader-layout-test--buffer "rollback-side"))
           (reader-window (selected-window))
           group)
      (unwind-protect
          (progn
            (set-window-buffer reader-window reader)
            (setq group
                  (epub-reader-layout-create reader (selected-frame)))
            (epub-reader-layout-manage-window
             group reader-window reader 'reader)

            (should-error
             (cl-letf (((symbol-function 'display-buffer)
                        (lambda (&rest _ignored)
                          (split-window-right)
                          (error "Injected display failure"))))
               (epub-reader-layout-display-side-buffer
                group side 'toc 'left 0 18)))

            (should (= (length (window-list nil 'no-minibuffer)) 1))
            (should (eq (window-buffer reader-window) reader))
            (should (eq (epub-reader-layout-window group 'reader)
                        reader-window))
            (should (epub-reader-layout-live-p group))
            (should (memq group epub-reader-layout--groups))
            (should (epub-reader-layout-test--hook-installed-p
                     'buffer-list-update-hook))
            (should (epub-reader-layout-test--hook-installed-p
                     'window-configuration-change-hook)))
        (when (epub-reader-layout-live-p group)
          (epub-reader-layout-release group))
        (dolist (buffer (list reader side))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest epub-reader-layout-fit-side-width-at-80-100-120 ()
  (should (equal (epub-reader-layout-fit-side 80 34 40 20)
                 '(side . 34)))
  (should (equal (epub-reader-layout-fit-side 46 42 40 20)
                 '(bottom . 10)))
  (should (equal (epub-reader-layout-fit-side 66 42 40 20)
                 '(side . 26)))
  (should (equal (epub-reader-layout-fit-side 86 42 40 20)
                 '(side . 42)))
  (should (equal (epub-reader-layout-fit-side 200 42 40 20)
                 '(side . 42))))

(ert-deftest epub-reader-layout-narrow-reader-reuses-one-panel-host ()
  (let ((epub-reader-open-full-frame t)
        reader toc annotations)
    (save-window-excursion
      (delete-other-windows)
      (setq reader
            (epub-reader-open (epub-reader-test-fixture "epub2.epub")))
      (unwind-protect
          (progn
            (with-current-buffer reader
              (setq toc (epub-reader-toc)))
            (select-window (get-buffer-window reader t))
            (with-current-buffer reader
              (setq annotations (epub-reader-annotations)))
            (let ((reader-window (get-buffer-window reader t))
                  (toc-window (get-buffer-window toc t))
                  (annotations-window (get-buffer-window annotations t)))
              (should (eq annotations toc))
              (should (eq toc-window annotations-window))
              (should (eq (plist-get (buffer-local-value 'textui-state toc)
                                     :view)
                          'annotations))
              (should (eq (window-parameter annotations-window 'window-side)
                          'right))
              (should (= (length (epub-reader-layout-side-windows
                                  (with-current-buffer reader
                                    epub-reader-ui--layout-group)))
                         1))
              (should (>= (window-total-width reader-window) 40))))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p toc) (kill-buffer toc))
        (when (buffer-live-p annotations) (kill-buffer annotations))))))

(ert-deftest epub-reader-layout-split-reader-keeps-minimum-width ()
  (let ((epub-reader-open-full-frame nil)
        (user-buffer (generate-new-buffer "*epub-reader-layout-user*"))
        reader annotations group reader-window user-window)
    (save-window-excursion
      (delete-other-windows)
      (unwind-protect
          (progn
            (setq reader
                  (epub-reader-ui-open
                   (epub-reader-test-fixture "epub2.epub")))
            (delete-other-windows)
            (setq reader-window (selected-window)
                  user-window (split-window-right))
            (set-window-buffer reader-window reader)
            (set-window-buffer user-window user-buffer)
            (select-window reader-window)
            (with-current-buffer reader
              (setq group (epub-reader-ui--ensure-layout reader)
                    annotations (epub-reader-annotations)))
            (let ((annotations-window (get-buffer-window annotations t)))
              (should
               (or (eq (window-parameter annotations-window 'window-side)
                       'bottom)
                   (>= (window-total-width reader-window) 40))))
            (should (eq (window-buffer user-window) user-buffer))
            (should (epub-reader-layout-live-p group)))
        (when (buffer-live-p reader) (kill-buffer reader))
        (when (buffer-live-p annotations) (kill-buffer annotations))
        (when (buffer-live-p user-buffer) (kill-buffer user-buffer))))))

(ert-deftest epub-reader-layout-quit-with-auxiliary-restores-configuration ()
  (let ((epub-reader-open-full-frame t)
        (first (epub-reader-layout-test--buffer "original-first"))
        (second (epub-reader-layout-test--buffer "original-second"))
        reader toc group)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-window-buffer (selected-window) first)
          (set-window-buffer (split-window-right) second)
          (setq reader
                (epub-reader-open
                 (epub-reader-test-fixture "epub2.epub")))
          (setq group
                (with-current-buffer reader
                  epub-reader-ui--layout-group))
          (with-current-buffer reader
            (setq toc (epub-reader-toc)))
          (with-current-buffer reader
            (epub-reader-quit))
          (should-not (buffer-live-p reader))
          (should-not (buffer-live-p toc))
          (should-not (epub-reader-layout-live-p group))
          (should-not (memq group epub-reader-layout--groups))
          (should-not (epub-reader-layout-test--hook-installed-p
                       'buffer-list-update-hook))
          (should-not (epub-reader-layout-test--hook-installed-p
                       'window-configuration-change-hook))
          (should (= (length (window-list nil 'no-minibuffer)) 2))
          (should (memq first (mapcar #'window-buffer
                                     (window-list nil 'no-minibuffer))))
          (should (memq second (mapcar #'window-buffer
                                      (window-list nil 'no-minibuffer)))))
      (dolist (buffer (list reader toc first second))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'epub-reader-layout-test)
;;; epub-reader-layout-test.el ends here
