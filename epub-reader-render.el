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

(cl-defstruct (epub-reader-block
               (:constructor epub-reader-block--create))
  "One semantic block extracted from a spine document."
  key kind text document-path element-id level image-file image-alt)

(defun epub-reader-render--local-name (node)
  "Return namespace-independent local tag name of XML NODE."
  (let ((name (car node)))
    (if (consp name) (cdr name) (symbol-name name))))

(defun epub-reader-render--element-p (object)
  "Return non-nil when OBJECT is an XML element node."
  (and (consp object)
       (let ((name (car object)))
         (or (symbolp name)
             (and (consp name) (stringp (car name))
                  (stringp (cdr name)))))))

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
      (let ((attribute-name (car attribute)))
        (equal (if (consp attribute-name)
                   (cdr attribute-name)
                 (symbol-name attribute-name))
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
              (text (epub-reader-render--inline child))
              (rendered
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
                       (list 'epub-reader-href href)
                       result))
                    result))
                 ("br" (propertize "\n" 'epub-reader-hard-break t))
                 ((or "img" "image") "")
                 ((or "ul" "ol" "table") "")
                 (_ text)))
              (id (epub-reader-render--attribute child "id")))
         (when id
           (if (string-empty-p rendered)
               (setq rendered (propertize "\u2060" 'display ""))
             (setq rendered (copy-sequence rendered)))
           (put-text-property 0 1 'epub-reader-anchor-id id rendered))
         rendered))))
   (cddr node) ""))

(defun epub-reader-render--xml-whitespace-p (character)
  "Return non-nil when CHARACTER is collapsible XML whitespace."
  (memq character '(?\s ?\t ?\r ?\n)))

(defun epub-reader-render--cjk-context-p (character)
  "Return non-nil when CHARACTER participates in CJK line joining."
  (and character
       (> character 127)
       (or (and (>= character #x2e80) (<= character #x9fff))
           (and (>= character #xac00) (<= character #xd7af))
           (and (>= character #xf900) (<= character #xfaff))
           (and (>= character #xff00) (<= character #xffef))
           (let ((categories (char-category-set character)))
             (or (aref categories ?c)
                 (aref categories ?h)
                 (aref categories ?j))))))

(defun epub-reader-render--previous-content-character ()
  "Return the previous non-anchor character in the current buffer."
  (save-excursion
    (let ((position (1- (point)))
          character)
      (while (and (>= position (point-min)) (null character))
        (let ((candidate (char-after position)))
          (unless (= candidate #x2060)
            (setq character candidate)))
        (setq position (1- position)))
      character)))

(defun epub-reader-render--next-content-character (string position)
  "Return STRING's next non-anchor character at or after POSITION."
  (let ((length (length string))
        character)
    (while (and (< position length) (null character))
      (let ((candidate (aref string position)))
        (unless (= candidate #x2060)
          (setq character candidate)))
      (setq position (1+ position)))
    character))

(defun epub-reader-render--normalize-inline (string)
  "Normalize XML whitespace in attributed STRING.

Explicit spaces collapse to one space.  A source segment break between CJK
characters (including full-width punctuation) disappears, while a segment
break between non-CJK words becomes one space.  Newlines carrying the
`epub-reader-hard-break' property are preserved exactly."
  (with-temp-buffer
    (let ((position 0)
          (length (length string)))
      (while (< position length)
        (let ((character (aref string position)))
          (cond
           ((get-text-property position 'epub-reader-hard-break string)
            (insert (substring string position (1+ position)))
            (setq position (1+ position)))
           ((epub-reader-render--xml-whitespace-p character)
            (let ((start position)
                  segment-break)
              (while (and (< position length)
                          (epub-reader-render--xml-whitespace-p
                           (aref string position))
                          (not (get-text-property
                                position 'epub-reader-hard-break string)))
                (when (memq (aref string position) '(?\r ?\n))
                  (setq segment-break t))
                (setq position (1+ position)))
              (let ((previous
                     (epub-reader-render--previous-content-character))
                    (next
                     (epub-reader-render--next-content-character
                      string position)))
                (when (and previous next
                           (not (= previous ?\n))
                           (not (get-text-property
                                 position 'epub-reader-hard-break string))
                           (not (and segment-break
                                     (epub-reader-render--cjk-context-p
                                      previous)
                                     (epub-reader-render--cjk-context-p
                                      next))))
                  (insert
                   (apply #'propertize " "
                          (text-properties-at start string)))))))
           (t
            (insert (substring string position (1+ position)))
            (setq position (1+ position)))))))
    (buffer-string)))

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

(defun epub-reader-render--image-data (publication section node)
  "Return (FILE ALT) for image NODE in SECTION of PUBLICATION."
  (let ((source (or (epub-reader-render--attribute node "src")
                    (epub-reader-render--attribute node "href")))
        (alt (or (epub-reader-render--attribute node "alt") "Image")))
    (if (not source)
        (list nil alt)
      (condition-case nil
          (let ((target
                 (epub-reader-publication-resolve-resource
                  publication section source)))
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

(defun epub-reader-render-section (publication section)
  "Return semantic blocks for parsed SECTION in PUBLICATION."
  (unless (epub-reader-section-p section)
    (signal 'wrong-type-argument (list 'epub-reader-section-p section)))
  (let* ((document-path (epub-reader-section-path section))
           (root (epub-reader-section-document section))
           (body (or (epub-reader-render--descendant root "body") root))
           blocks)
      (cl-labels
          ((emit (kind node text path &optional level image-file image-alt)
             (let* ((id (epub-reader-render--attribute node "id"))
                    (anchor-text
                     (if (string-empty-p text)
                         (propertize "\u2060" 'display "")
                       (copy-sequence text)))
                    (_anchor-property
                     (when id
                       (put-text-property
                        0 1 'epub-reader-anchor-id id anchor-text)))
                    (key (if id (concat "id:" id) (concat "path:" path)))
                      (face
                       (pcase kind
                         ('heading (epub-reader-render--heading-face level))
                         ('quote 'epub-reader-quote-face)
                         ('code 'epub-reader-code-face)
                         ('image 'epub-reader-image-alt-face)
                         (_ 'epub-reader-prose-face)))
                      (attributed
                       (epub-reader-locator-attach-source
                        (epub-reader-render--add-face anchor-text face)
                        document-path key)))
               (push
                (epub-reader-block--create
                 :key key :kind kind :text attributed
                 :document-path document-path :element-id id :level level
                 :image-file image-file :image-alt image-alt)
                blocks)))
           (emit-image (node path)
             (pcase-let ((`(,file ,alt)
                           (epub-reader-render--image-data
                            publication section node)))
               (emit 'image node (format "[%s]" alt) path nil file alt)))
           (walk-children (node context path)
             (cl-loop
              for child in (epub-reader-render--children node)
              for index from 0
              do (walk child context
                       (format "%s/%d:%s" path index
                               (epub-reader-render--local-name child)))))
           (walk (node context path)
             (let ((tag (epub-reader-render--local-name node)))
               (cond
                ((string-match-p "\\`h[1-6]\\'" tag)
                 (let ((level (epub-reader-render--heading-level tag)))
                   (emit 'heading node
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline node))
                         path level)))
                ((equal tag "p")
                 (emit (or context 'paragraph) node
                       (epub-reader-render--normalize-inline
                        (epub-reader-render--inline node)) path)
                 (dolist (image (epub-reader-render--descendants node "img"))
                   (emit-image image (concat path "/image"))))
                ((equal tag "blockquote")
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (walk-children node 'quote path))
                ((equal tag "pre")
                 (emit 'code node
                       (string-trim-right
                        (epub-reader-render--raw-text node)) path))
                ((member tag '("ul" "ol"))
                 (walk-children node 'list-item path))
                ((equal tag "li")
                 (emit (or context 'list-item) node
                       (epub-reader-render--normalize-inline
                        (epub-reader-render--inline node)) path)
                 (cl-loop
                  for child in (epub-reader-render--children node)
                  for index from 0
                  when (member (epub-reader-render--local-name child)
                               '("ul" "ol"))
                  do (walk child nil
                           (format "%s/%d:%s" path index
                                   (epub-reader-render--local-name child)))))
                ((member tag '("img" "image")) (emit-image node path))
                ((equal tag "figure")
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (dolist (image (epub-reader-render--descendants node "img"))
                   (emit-image image (concat path "/image")))
                 (dolist (caption
                          (epub-reader-render--children node "figcaption"))
                   (emit 'paragraph caption
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline caption))
                         (concat path "/caption"))))
                ((equal tag "table")
                 (emit 'code node (epub-reader-render--table-text node) path))
                (t
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (walk-children node context path))))))
        (walk-children body nil "body"))
    (nreverse blocks)))

(defun epub-reader-render-chapter (publication spine-index)
  "Load and return semantic blocks at PUBLICATION's SPINE-INDEX."
  (epub-reader-render-section
   publication
   (epub-reader-publication-load-section publication spine-index)))

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
     (let* ((source
             (get-text-property 0 'epub-reader-source
                                (epub-reader-block-text block)))
            (image-alt (copy-sequence (epub-reader-block-text block)))
            (_image-anchor
             (when source
               (put-text-property
                0 (length image-alt) 'epub-reader-image-anchor
                (cons source epub-reader-image-rows) image-alt)))
            (caption
            (epub-reader-render--text-element
             (epub-reader-block-text block))))
       (if (epub-reader-block-image-file block)
           (list :type :flex :direction :column :gap 0
                 :children
                 (list
                  (list :type :image
                        :file (epub-reader-block-image-file block)
                        :rows epub-reader-image-rows
                        :alt image-alt
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
