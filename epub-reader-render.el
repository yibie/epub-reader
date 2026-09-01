;;; epub-reader-render.el --- Render EPUB XHTML as TextUI frames -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Convert one XHTML spine resource into semantic blocks, then convert those
;; blocks into public TextUI :text/:image/flex elements.  Source properties are
;; attached before layout so locator identity survives width changes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'epub-reader-locator)
(require 'epub-reader-publication)

(declare-function epub-reader-follow-link "epub-reader-ui" ())
(declare-function epub-reader-follow-link-mouse "epub-reader-ui" (event))

(defcustom epub-reader-image-rows 16
  "Number of text rows allocated to an EPUB image in the first release."
  :type 'integer
  :group 'epub-reader)

(defface epub-reader-heading-1-face
  '((t (:inherit variable-pitch :weight bold :height 1.45)))
  "Face for top-level EPUB headings."
  :group 'epub-reader)

(defface epub-reader-heading-2-face
  '((t (:inherit variable-pitch :weight bold :height 1.25)))
  "Face for second-level EPUB headings."
  :group 'epub-reader)

(defface epub-reader-heading-3-face
  '((t (:inherit variable-pitch :weight bold :height 1.12)))
  "Face for lower-level EPUB headings."
  :group 'epub-reader)

(defface epub-reader-prose-face
  '((t (:inherit variable-pitch)))
  "Face for ordinary EPUB prose."
  :group 'epub-reader)

(defface epub-reader-emphasis-face
  '((t (:slant italic)))
  "Face for emphasized inline text."
  :group 'epub-reader)

(defface epub-reader-strong-face
  '((t (:weight bold)))
  "Face for strongly emphasized inline text."
  :group 'epub-reader)

(defface epub-reader-quote-face
  '((t (:inherit variable-pitch :slant italic :foreground "gray55")))
  "Face for block quotations."
  :group 'epub-reader)

(defface epub-reader-code-face
  '((t (:inherit fixed-pitch :background "gray92")))
  "Face for inline and block code."
  :group 'epub-reader)

(defface epub-reader-link-face
  '((t (:inherit link)))
  "Face for EPUB hyperlinks."
  :group 'epub-reader)

(defface epub-reader-image-alt-face
  '((t (:inherit shadow :slant italic)))
  "Face for image alternative text."
  :group 'epub-reader)

(defvar epub-reader-render-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'epub-reader-follow-link)
    (define-key map [mouse-1] #'epub-reader-follow-link-mouse)
    map)
  "Text-property keymap attached to rendered EPUB links.")

(cl-defstruct (epub-reader-block
               (:constructor epub-reader-block--create))
  "One semantic block extracted from a spine document."
  key kind text document-path element-id level image-file image-alt)

(defun epub-reader-render--local-name (node)
  "Return namespace-independent local tag name of XML NODE."
  (let ((name (symbol-name (car node))))
    (if (string-match "\\([^:]+\\)\\'" name)
        (match-string 1 name)
      name)))

(defun epub-reader-render--element-p (object)
  "Return non-nil when OBJECT is an XML element node."
  (and (consp object) (symbolp (car object))))

(defun epub-reader-render--children (node &optional name)
  "Return NODE's direct element children, optionally matching local NAME."
  (cl-remove-if-not
   (lambda (child)
     (and (epub-reader-render--element-p child)
          (or (null name)
              (equal (epub-reader-render--local-name child) name))))
   (cddr node)))

(defun epub-reader-render--descendant (node name)
  "Return NODE's first descendant with local NAME."
  (catch 'found
    (dolist (child (epub-reader-render--children node))
      (when (equal (epub-reader-render--local-name child) name)
        (throw 'found child))
      (let ((nested (epub-reader-render--descendant child name)))
        (when nested (throw 'found nested))))
    nil))

(defun epub-reader-render--descendants (node name)
  "Return all NODE descendants with local NAME in document order."
  (cl-mapcan
   (lambda (child)
     (append (when (equal (epub-reader-render--local-name child) name)
               (list child))
             (epub-reader-render--descendants child name)))
   (epub-reader-render--children node)))

(defun epub-reader-render--attribute (node name)
  "Return NODE attribute with local NAME."
  (cdr
   (cl-find-if
    (lambda (attribute)
      (let ((attribute-name (symbol-name (car attribute))))
        (equal (if (string-match "\\([^:]+\\)\\'" attribute-name)
                   (match-string 1 attribute-name)
                 attribute-name)
               name)))
    (cadr node))))

(defun epub-reader-render--raw-text (node)
  "Return all descendant text of NODE without whitespace normalization."
  (mapconcat
   (lambda (child)
     (cond
      ((stringp child) child)
      ((epub-reader-render--element-p child)
       (epub-reader-render--raw-text child))
      (t "")))
   (cddr node) ""))

(defun epub-reader-render--add-face (string face)
  "Return STRING with FACE added without replacing nested faces."
  (let ((result (copy-sequence string)))
    (when (> (length result) 0)
      (add-face-text-property 0 (length result) face t result))
    result))

(defun epub-reader-render--inline (node)
  "Return attributed inline text represented by NODE."
  (mapconcat
   (lambda (child)
     (cond
      ((stringp child) child)
      ((not (epub-reader-render--element-p child)) "")
      (t
       (let* ((tag (epub-reader-render--local-name child))
              (text (epub-reader-render--inline child)))
         (pcase tag
           ((or "em" "i")
            (epub-reader-render--add-face
             text 'epub-reader-emphasis-face))
           ((or "strong" "b")
            (epub-reader-render--add-face
             text 'epub-reader-strong-face))
           ("code"
            (epub-reader-render--add-face text 'epub-reader-code-face))
           ("a"
            (let ((href (epub-reader-render--attribute child "href"))
                  (result (epub-reader-render--add-face
                           text 'epub-reader-link-face)))
              (when (and href (> (length result) 0))
                (add-text-properties
                 0 (length result)
                 (list 'epub-reader-href href
                       'help-echo href
                       'mouse-face 'highlight
                       'follow-link t
                       'keymap epub-reader-render-link-map)
                 result))
              result))
           ("br" "\n")
           ("img" "")
           ((or "ul" "ol" "table") "")
           (_ text))))))
   (cddr node) ""))

(defun epub-reader-render--normalize-inline (string)
  "Collapse horizontal/XML indentation whitespace in attributed STRING."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (while (re-search-forward "[ \t\r\n]+" nil t)
      (replace-match " " t t))
    (string-trim (buffer-string))))

(defun epub-reader-render--heading-level (tag)
  "Return numeric heading level for TAG."
  (if (string-match "\\`h\\([1-6]\\)\\'" tag)
      (string-to-number (match-string 1 tag))
    3))

(defun epub-reader-render--heading-face (level)
  "Return face symbol for heading LEVEL."
  (cond ((<= level 1) 'epub-reader-heading-1-face)
        ((= level 2) 'epub-reader-heading-2-face)
        (t 'epub-reader-heading-3-face)))

(defun epub-reader-render--image-data (publication document-path node)
  "Return (FILE ALT) for image NODE in DOCUMENT-PATH of PUBLICATION."
  (let ((source (or (epub-reader-render--attribute node "src")
                    (epub-reader-render--attribute node "href")))
        (alt (or (epub-reader-render--attribute node "alt") "Image")))
    (if (not source)
        (list nil alt)
      (condition-case nil
          (let ((target
                 (epub-reader-publication-resolve-href
                  publication document-path source)))
            (list (and (not (epub-reader-link-target-external-p target))
                       (file-readable-p (epub-reader-link-target-file target))
                       (epub-reader-link-target-file target))
                  alt))
        (error (list nil alt))))))

(defun epub-reader-render--table-text (node)
  "Return a readable plain-text representation of table NODE."
  (mapconcat
   (lambda (row)
     (mapconcat
      (lambda (cell)
        (epub-reader-render--normalize-inline
         (epub-reader-render--inline cell)))
      (cl-remove-if-not
       (lambda (child)
         (member (epub-reader-render--local-name child) '("td" "th")))
       (epub-reader-render--children row))
      " | "))
   (epub-reader-render--descendants node "tr") "\n"))

(defun epub-reader-render--document-dom (resource)
  "Parse XHTML RESOURCE and return its document element."
  (epub-reader-publication--parse-file (epub-reader-resource-file resource)))

(defun epub-reader-render-chapter (publication spine-index)
  "Return semantic blocks for PUBLICATION at zero-based SPINE-INDEX."
  (let ((resource
         (epub-reader-publication-spine-resource publication spine-index)))
    (unless resource
      (signal 'args-out-of-range
              (list spine-index
                    (length (epub-reader-publication-spine publication)))))
    (let* ((document-path (epub-reader-resource-path resource))
           (root (epub-reader-render--document-dom resource))
           (body (or (epub-reader-render--descendant root "body") root))
           (counter 0)
           blocks)
      (cl-labels
          ((emit (kind node text &optional level image-file image-alt)
             (unless (string-empty-p text)
               (let* ((id (epub-reader-render--attribute node "id"))
                      (key (format "b%05d%s" counter
                                   (if id (concat ":" id) "")))
                      (face
                       (pcase kind
                         ('heading (epub-reader-render--heading-face level))
                         ('quote 'epub-reader-quote-face)
                         ('code 'epub-reader-code-face)
                         ('image 'epub-reader-image-alt-face)
                         (_ 'epub-reader-prose-face)))
                      (attributed
                       (epub-reader-locator-attach-source
                        (epub-reader-render--add-face text face)
                        document-path key)))
                 (cl-incf counter)
                 (push
                  (epub-reader-block--create
                   :key key :kind kind :text attributed
                   :document-path document-path :element-id id :level level
                   :image-file image-file :image-alt image-alt)
                  blocks))))
           (emit-image (node)
             (pcase-let ((`(,file ,alt)
                           (epub-reader-render--image-data
                            publication document-path node)))
               (emit 'image node (format "[%s]" alt) nil file alt)))
           (walk (node &optional context)
             (let ((tag (epub-reader-render--local-name node)))
               (cond
                ((string-match-p "\\`h[1-6]\\'" tag)
                 (let ((level (epub-reader-render--heading-level tag)))
                   (emit 'heading node
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline node))
                         level)))
                ((equal tag "p")
                 (emit (or context 'paragraph) node
                       (epub-reader-render--normalize-inline
                        (epub-reader-render--inline node)))
                 (dolist (image (epub-reader-render--descendants node "img"))
                   (emit-image image)))
                ((equal tag "blockquote")
                 (dolist (child (epub-reader-render--children node))
                   (walk child 'quote)))
                ((equal tag "pre")
                 (emit 'code node
                       (string-trim-right
                        (epub-reader-render--raw-text node))))
                ((member tag '("ul" "ol"))
                 (dolist (child (epub-reader-render--children node "li"))
                   (walk child 'list-item)))
                ((equal tag "li")
                 (emit (or context 'list-item) node
                       (epub-reader-render--normalize-inline
                        (epub-reader-render--inline node)))
                 (dolist (child (epub-reader-render--children node))
                   (when (member (epub-reader-render--local-name child)
                                 '("ul" "ol"))
                     (walk child))))
                ((member tag '("img" "image")) (emit-image node))
                ((equal tag "figure")
                 (dolist (image (epub-reader-render--descendants node "img"))
                   (emit-image image))
                 (dolist (caption
                          (epub-reader-render--children node "figcaption"))
                   (emit 'paragraph caption
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline caption)))))
                ((equal tag "table")
                 (emit 'code node (epub-reader-render--table-text node)))
                (t
                 (dolist (child (epub-reader-render--children node))
                   (walk child context)))))))
        (dolist (child (epub-reader-render--children body))
          (walk child)))
      (nreverse blocks))))

(defun epub-reader-render--text-element (value)
  "Return a width-aware TextUI prose element for VALUE."
  (list :type :text :value value :layout '(:min-width 20 :grow 1)))

(defun epub-reader-render-block-element (block)
  "Convert semantic BLOCK to one public TextUI element."
  (pcase (epub-reader-block-kind block)
    ('quote
     (list :type :flex :direction :column :border t :padding 1
           :children
           (list (epub-reader-render--text-element
                  (epub-reader-block-text block)))))
    ('code
     (list :type :flex :direction :column :border t :padding 1
           :children
           (list (epub-reader-render--text-element
                  (epub-reader-block-text block)))))
    ('list-item
     (epub-reader-render--text-element
      (concat "• " (epub-reader-block-text block))))
    ('image
     (let ((caption
            (epub-reader-render--text-element
             (epub-reader-block-text block))))
       (if (epub-reader-block-image-file block)
           (list :type :flex :direction :column :gap 0
                 :children
                 (list
                  (list :type :image
                        :file (epub-reader-block-image-file block)
                        :rows epub-reader-image-rows
                        :alt (epub-reader-block-image-alt block)
                        :layout '(:min-width 12 :grow 1))
                  caption))
         caption)))
    (_ (epub-reader-render--text-element
        (epub-reader-block-text block)))))

(defun epub-reader-render-blocks (blocks)
  "Convert semantic BLOCKS to a list of public TextUI elements."
  (mapcar #'epub-reader-render-block-element blocks))

(provide 'epub-reader-render)
;;; epub-reader-render.el ends here
