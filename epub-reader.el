;;; epub-reader.el --- Read EPUB publications with TextUI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (textui "0.5.1"))
;; Keywords: multimedia, hypermedia

;;; Commentary:

;; Add both this directory and the TextUI checkout to `load-path', require this
;; package, then run `M-x epub-reader-open'.

;;; Code:

(require 'epub-reader-ui)

;;;###autoload
(defun epub-reader-open (file)
  "Open EPUB FILE in a width-aware TextUI reader."
  (interactive "fOpen EPUB: ")
  (epub-reader-ui-open-and-display file))

(provide 'epub-reader)
;;; epub-reader.el ends here
