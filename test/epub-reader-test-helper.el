;;; epub-reader-test-helper.el --- Test support -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(defconst epub-reader-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun epub-reader-test-fixture (name)
  "Return absolute fixture path for NAME."
  (expand-file-name name
                    (expand-file-name "fixtures" epub-reader-test--directory)))

(provide 'epub-reader-test-helper)
;;; epub-reader-test-helper.el ends here
