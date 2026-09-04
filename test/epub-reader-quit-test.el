;;; epub-reader-quit-test.el --- Reader quit layout tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-test-helper)

(defun epub-reader-quit-test--buffer (name)
  "Return a fresh test buffer named with NAME."
  (generate-new-buffer (format "*epub-reader-quit-%s*" name)))

(defun epub-reader-quit-test--hook-installed-p (hook)
  "Return non-nil when layout change detection is registered on HOOK."
  (memq #'epub-reader-layout--check-windows (default-value hook)))

(ert-deftest epub-reader-quit-keeps-user-split-when-full-frame-disabled ()
  (let ((epub-reader-open-full-frame nil)
        (first (epub-reader-quit-test--buffer "first"))
        (second (epub-reader-quit-test--buffer "second"))
        reader toc group)
    (save-window-excursion
      (delete-other-windows)
      (let ((first-window (selected-window))
            (second-window (split-window-right)))
        (select-window first-window)
        (switch-to-buffer first)
        (set-window-buffer second-window second)
        (unwind-protect
            (progn
              (setq reader
                    (epub-reader-open
                     (epub-reader-test-fixture "epub2.epub")))
              (setq group
                    (with-current-buffer reader
                      epub-reader-ui--layout-group))
              (with-current-buffer reader
                (setq toc (epub-reader-toc)))
              (select-window (get-buffer-window reader t))
              (with-current-buffer reader
                (epub-reader-quit))
              (should-not (buffer-live-p reader))
              (should-not (buffer-live-p toc))
              (should-not (epub-reader-layout-live-p group))
              (should (= (length (window-list nil 'no-minibuffer)) 2))
              (should (eq (window-buffer first-window) first))
              (should (eq (window-buffer second-window) second))
              (should-not (epub-reader-quit-test--hook-installed-p
                           'buffer-list-update-hook))
              (should-not (epub-reader-quit-test--hook-installed-p
                           'window-configuration-change-hook)))
          (when (buffer-live-p reader)
            (with-current-buffer reader
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer reader))
          (dolist (buffer (list toc first second))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest epub-reader-quit-refused-by-query-leaves-layout-intact ()
  (let ((epub-reader-open-full-frame nil)
        (original (epub-reader-quit-test--buffer "query-original"))
        reader toc group reader-window toc-window)
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) original)
      (unwind-protect
          (progn
            (let ((display-buffer-overriding-action
                   '((display-buffer-same-window))))
              (setq reader
                    (epub-reader-open
                     (epub-reader-test-fixture "epub2.epub"))))
            (setq reader-window (get-buffer-window reader t)
                  group (with-current-buffer reader
                          epub-reader-ui--layout-group))
            (with-current-buffer reader
              (setq toc (epub-reader-toc)))
            (with-current-buffer reader
              (add-hook 'kill-buffer-query-functions
                        (lambda () nil) nil t))
            (setq toc-window (get-buffer-window toc t))

            (select-window reader-window)
            (with-current-buffer reader
              (epub-reader-quit))

            (should (buffer-live-p reader))
            (should (buffer-live-p toc))
            (should (window-live-p reader-window))
            (should (window-live-p toc-window))
            (should (eq (window-buffer reader-window) reader))
            (should (eq (window-buffer toc-window) toc))
            (should (epub-reader-layout-live-p group))
            (should (eq (epub-reader-layout-window group 'reader)
                        reader-window))
            (should (eq (epub-reader-layout-window group 'panel) toc-window)))
        (when (buffer-live-p reader)
          (with-current-buffer reader
            (setq-local kill-buffer-query-functions nil))
          (kill-buffer reader))
        (dolist (buffer (list toc original))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest epub-reader-quit-with-two-readers-keeps-other-session ()
  (let ((epub-reader-open-full-frame nil)
        reader-a reader-b toc-a toc-b group-a group-b panel-a panel-b
        reader-a-window reader-b-window toc-b-window)
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
            (setq reader-a-window (selected-window)
                  reader-b-window (split-window-right))
            (set-window-buffer reader-a-window reader-a)
            (set-window-buffer reader-b-window reader-b)
            (select-window reader-a-window)
            (with-current-buffer reader-a
              (setq group-a (epub-reader-ui--ensure-layout reader-a)
                    toc-a (epub-reader-toc)))
            (select-window reader-b-window)
            (with-current-buffer reader-b
              (setq group-b (epub-reader-ui--ensure-layout reader-b)
                    toc-b (epub-reader-toc)))
            (setq panel-a
                  (with-current-buffer reader-a
                    (epub-reader-session-panel epub-reader-ui--session))
                  panel-b
                  (with-current-buffer reader-b
                    (epub-reader-session-panel epub-reader-ui--session)))
            (should (epub-reader-panel-live-p panel-a))
            (should (epub-reader-panel-live-p panel-b))
            (should-not (eq panel-a panel-b))
            (setq toc-b-window (get-buffer-window toc-b t))

            (select-window reader-a-window)
            (with-current-buffer reader-a
              (epub-reader-quit))

            (should-not (buffer-live-p reader-a))
            (should-not (buffer-live-p toc-a))
            (should-not (epub-reader-panel-live-p panel-a))
            (should-not (epub-reader-layout-live-p group-a))
            (should (buffer-live-p reader-b))
            (should (buffer-live-p toc-b))
            (should (epub-reader-panel-live-p panel-b))
            (should (window-live-p reader-b-window))
            (should (window-live-p toc-b-window))
            (should (eq (window-buffer reader-b-window) reader-b))
            (should (eq (window-buffer toc-b-window) toc-b))
            (should (epub-reader-layout-live-p group-b))
            (should (eq (epub-reader-layout-window group-b 'reader)
                        reader-b-window))
            (should (epub-reader-quit-test--hook-installed-p
                     'buffer-list-update-hook))
            (should (epub-reader-quit-test--hook-installed-p
                     'window-configuration-change-hook)))
        (dolist (reader (list reader-a reader-b))
          (when (buffer-live-p reader)
            (with-current-buffer reader
              (setq-local kill-buffer-query-functions nil))
            (kill-buffer reader)))
        (dolist (buffer (list toc-a toc-b))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'epub-reader-quit-test)
;;; epub-reader-quit-test.el ends here
