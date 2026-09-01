;;; epub-reader-render.el --- Render EPUB XHTML as TextUI frames -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Convert one XHTML spine resource into semantic blocks, then convert those
;; blocks into public TextUI :text/:image/flex elements.  Cached blocks keep
;; canonical attributed text; source offsets are materialized only for blocks
;; entering the active TextUI chunk.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'epub-reader-locator)
(require 'epub-reader-publication)

(defcustom epub-reader-image-rows 16
  "Number of text rows allocated to an EPUB image in the first release."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-text-wrap-strategy 'greedy
  "TextUI wrapping strategy used for EPUB prose.
`greedy' is kinsoku-aware and optimized for interactive reading latency.
`balanced' retains full Knuth--Plass justification at a higher CPU cost."
  :type '(choice (const :tag "Low-latency greedy" greedy)
                 (const :tag "Balanced Knuth--Plass" balanced))
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

(defface epub-reader-image-error-face
  '((t (:inherit error :slant italic)))
  "Face for visible image resource diagnostics."
  :group 'epub-reader)

(defface epub-reader-highlight-face
  '((t (:background "#fff2a8" :foreground "#1f1f1f")))
  "Face for an EPUB text highlight."
  :group 'epub-reader)

(defface epub-reader-highlight-degraded-face
  '((t (:inherit epub-reader-highlight-face :underline (:style wave))))
  "Face for a highlight restored from its quoted text."
  :group 'epub-reader)

(defconst epub-reader-render--xml-namespace
  "http://www.w3.org/XML/1998/namespace")

(defconst epub-reader-render--pending-image-file
  (expand-file-name ".epub-reader-pending-image" temporary-file-directory)
  "Unreadable sentinel used for fixed-row asynchronous image placeholders.")

(cl-defstruct (epub-reader-block
               (:constructor epub-reader-block--create))
  "One semantic block extracted from a spine document."
  key kind text document-path book-key spine-index element-id level image-file
  image-href image-alt image-error list-marker)

(cl-defstruct (epub-reader-render-image
               (:constructor epub-reader-render-image--create))
  "Normalized image metadata carried while constructing a semantic block."
  href alt error)

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

(defun epub-reader-render--language (node inherited-language)
  "Return NODE's effective language, falling back to INHERITED-LANGUAGE."
  (or
   (cdr
    (cl-find-if
     (lambda (attribute)
       (let ((name (car attribute)))
         (and (consp name)
              (equal (car name) epub-reader-render--xml-namespace)
              (equal (cdr name) "lang"))))
     (cadr node)))
   (cdr
    (cl-find-if
     (lambda (attribute)
       (let ((name (car attribute)))
         (if (consp name)
             (and (equal (car name) "") (equal (cdr name) "lang"))
           (equal (symbol-name name) "lang"))))
     (cadr node)))
   inherited-language))

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

(defun epub-reader-render--inline-runs (node &optional inherited-language)
  "Return attributed strings and image tokens represented by NODE.
INHERITED-LANGUAGE is overridden by `xml:lang' or `lang' on descendants.
Image tokens are vectors whose second item is the source XML element."
  (let ((language
         (epub-reader-render--language node inherited-language)))
    (cl-mapcan
     (lambda (child)
       (cond
         ((stringp child)
          (let ((result (copy-sequence child)))
            (when language
              (put-text-property 0 (length result)
                                 'epub-reader-language language result))
            (list result)))
         ((not (epub-reader-render--element-p child)) nil)
         (t
          (let* ((tag (epub-reader-render--local-name child))
                 (child-language
                  (epub-reader-render--language child language))
                 (runs
                  (pcase tag
                    ((or "img" "image") (list (vector 'image child)))
                    ("br"
                     (list (propertize "\n" 'epub-reader-hard-break t)))
                    ((or "ul" "ol" "table") nil)
                    (_ (epub-reader-render--inline-runs child language))))
                 (face
                  (pcase tag
                    ((or "em" "i") 'epub-reader-emphasis-face)
                    ((or "strong" "b") 'epub-reader-strong-face)
                    ("code" 'epub-reader-code-face)
                    ("a" 'epub-reader-link-face)))
                 (href (and (equal tag "a")
                            (epub-reader-render--attribute child "href")))
                 (rendered
                  (mapcar
                   (lambda (run)
                     (if (not (stringp run))
                         run
                       (let ((result (if face
                                         (epub-reader-render--add-face run face)
                                       (copy-sequence run))))
                         (when (and href (> (length result) 0))
                           (add-text-properties
                            0 (length result)
                            (list 'epub-reader-href href) result))
                         result)))
                   runs))
                 (id (epub-reader-render--attribute child "id")))
            (when id
              (let ((first-text
                     (cl-find-if (lambda (run)
                                   (and (stringp run) (> (length run) 0)))
                                 rendered)))
                (if first-text
                    (put-text-property
                     0 1 'epub-reader-anchor-id id first-text)
                  (push (propertize "\u2060" 'display ""
                                    'epub-reader-language child-language
                                    'epub-reader-anchor-id id)
                        rendered))))
            rendered))))
     (cddr node))))

(defun epub-reader-render--inline (node &optional inherited-language)
  "Return attributed inline text represented by NODE, excluding images."
  (mapconcat (lambda (run) (if (stringp run) run ""))
             (epub-reader-render--inline-runs node inherited-language) ""))

(defun epub-reader-render--xml-whitespace-p (character)
  "Return non-nil when CHARACTER is collapsible XML whitespace."
  (memq character '(?\s ?\t ?\r ?\n)))

(defun epub-reader-render--cjk-context-p (character)
  "Return non-nil when CHARACTER participates in CJK line joining."
  (and character
       (> character 127)
       (or (and (>= character #x2e80) (<= character #x9fff))
           (and (>= character #xf900) (<= character #xfaff))
           (and (>= character #xff00) (<= character #xffef))
           (let ((categories (char-category-set character)))
             (or (aref categories ?c)
                 (aref categories ?j))))))

(defun epub-reader-render--language-prefix (language)
  "Return lowercase primary language subtag from LANGUAGE."
  (and language (not (string-empty-p language))
       (downcase (car (split-string language "[-_]" t)))))

(defun epub-reader-render--join-source-segment-p
    (previous next language)
  "Return non-nil when a source break joins PREVIOUS and NEXT in LANGUAGE."
  (and (member (epub-reader-render--language-prefix language) '("zh" "ja"))
       (epub-reader-render--cjk-context-p previous)
       (epub-reader-render--cjk-context-p next)))

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

(defun epub-reader-render--normalize-inline (string &optional language)
  "Normalize XML whitespace in attributed STRING.

Explicit spaces collapse to one space.  In zh/ja, a source segment break
between CJK characters (including full-width punctuation) disappears.  In ko
and other languages it becomes one space.  Newlines carrying the
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
                                     (epub-reader-render--join-source-segment-p
                                      previous next
                                      (or (get-text-property
                                           start 'epub-reader-language string)
                                          language)))))
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
  "Return (HREF ALT ERROR) for image NODE in SECTION of PUBLICATION.
This validates URL resolution without materializing the image member."
  (let ((source (or (epub-reader-render--attribute node "src")
                    (epub-reader-render--attribute node "href")))
        (alt (or (epub-reader-render--attribute node "alt") "Image")))
    (if (not source)
        (list nil alt "Image has no source URL")
      (condition-case error-data
          (let ((target
                 (epub-reader-publication-resolve-href
                  publication (epub-reader-section-base-path section)
                  source)))
            (if (epub-reader-link-target-external-p target)
                (list nil alt
                      (format "Remote image is unsupported: %s" source))
              (list source alt nil)))
        (error
         (list nil alt
               (format "Image error for %s: %s" source
                       (error-message-string error-data))))))))

(defun epub-reader-render--table-text (node language)
  "Return a readable plain-text representation of table NODE in LANGUAGE."
  (mapconcat
   (lambda (row)
     (mapconcat
      (lambda (cell)
        (epub-reader-render--normalize-inline
         (epub-reader-render--inline cell language) language))
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
           (root-language
            (epub-reader-render--language
             root (epub-reader-publication-language publication)))
           (body-language
            (epub-reader-render--language body root-language))
           blocks)
      (cl-labels
          ((emit (kind node text path &key level image list-marker)
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
                         ('image (if (and image
                                         (epub-reader-render-image-error image))
                                     'epub-reader-image-error-face
                                   'epub-reader-image-alt-face))
                         (_ 'epub-reader-prose-face)))
                      (attributed
                       (epub-reader-render--add-face anchor-text face)))
               (push
                (epub-reader-block--create
                 :key key :kind kind :text attributed
                 :document-path document-path
                 :book-key (epub-reader-publication-book-key publication)
                 :spine-index (epub-reader-section-spine-index section)
                 :element-id id :level level
                 :image-href (and image
                                  (epub-reader-render-image-href image))
                 :image-alt (and image
                                 (epub-reader-render-image-alt image))
                 :image-error (and image
                                   (epub-reader-render-image-error image))
                 :list-marker list-marker)
                blocks)))
           (emit-image (node path)
             (pcase-let ((`(,href ,alt ,image-error)
                           (epub-reader-render--image-data
                            publication section node)))
               (emit 'image node
                     (if image-error
                         (format "[%s — %s]" alt image-error)
                       (format "[%s]" alt))
                     path
                     :image
                     (epub-reader-render-image--create
                      :href href :alt alt :error image-error))))
           (node-without-id (node)
             (cons (car node)
                   (cons
                    (cl-remove-if
                     (lambda (attribute)
                       (equal
                        (if (consp (car attribute))
                            (cdr (car attribute))
                          (symbol-name (car attribute)))
                        "id"))
                     (copy-tree (cadr node)))
                    (cddr node))))
           (emit-inline-runs (kind node path language)
             (let* ((runs (epub-reader-render--inline-runs node language))
                    (has-image
                     (cl-some (lambda (run)
                                (and (vectorp run) (eq (aref run 0) 'image)))
                              runs)))
               (if (not has-image)
                   (emit kind node
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline node language) language)
                         path)
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (let ((text "")
                       (part 0)
                       (image-index 0)
                       (anonymous-node (node-without-id node)))
                   (cl-labels
                       ((flush-text ()
                          (let ((normalized
                                 (epub-reader-render--normalize-inline
                                  text language)))
                            (unless (string-empty-p normalized)
                              (emit kind anonymous-node normalized
                                    (format "%s/text:%d" path part))
                              (setq part (1+ part))))
                          (setq text "")))
                     (dolist (run runs)
                       (if (stringp run)
                           (setq text (concat text run))
                         (flush-text)
                         (emit-image (aref run 1)
                                     (format "%s/image:%d"
                                             path image-index))
                         (setq image-index (1+ image-index))))
                     (flush-text))))))
           (walk-list (node ordered-p path language)
             (let ((number
                    (if ordered-p
                        (let ((start
                               (epub-reader-render--attribute node "start")))
                          (if (and start
                                   (string-match-p "\\`-?[0-9]+\\'" start))
                              (string-to-number start)
                            1))
                      0)))
               (cl-loop
                for child in (epub-reader-render--children node)
                for index from 0
                when (equal (epub-reader-render--local-name child) "li")
                do (progn
                     (walk child
                           (if ordered-p (format "%d. " number) "• ")
                           (format "%s/%d:li" path index) language)
                     (setq number (1+ number))))))
           (walk-children (node context path language)
             (cl-loop
              for child in (epub-reader-render--children node)
              for index from 0
              do (walk child context
                       (format "%s/%d:%s" path index
                               (epub-reader-render--local-name child))
                       language)))
           (walk (node context path language)
             (let ((tag (epub-reader-render--local-name node))
                   (node-language
                    (epub-reader-render--language node language)))
               (cond
                ((string-match-p "\\`h[1-6]\\'" tag)
                 (let ((level (epub-reader-render--heading-level tag)))
                   (emit 'heading node
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline node node-language)
                          node-language)
                         path :level level)))
                ((equal tag "p")
                 (emit-inline-runs (or (and (symbolp context) context)
                                       'paragraph)
                                   node path node-language))
                ((equal tag "blockquote")
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (walk-children node 'quote path node-language))
                ((equal tag "pre")
                 (emit 'code node
                       (string-trim-right
                        (epub-reader-render--raw-text node)) path))
                ((member tag '("ul" "ol"))
                 (walk-list node (equal tag "ol") path node-language))
                ((equal tag "li")
                 (emit 'list-item node
                       (epub-reader-render--normalize-inline
                        (epub-reader-render--inline node node-language)
                        node-language)
                       path :list-marker
                       (if (stringp context) context "• "))
                 (cl-loop
                  for child in (epub-reader-render--children node)
                  for index from 0
                  when (member (epub-reader-render--local-name child)
                               '("ul" "ol"))
                  do (walk child nil
                           (format "%s/%d:%s" path index
                                   (epub-reader-render--local-name child))
                           node-language)))
                ((member tag '("img" "image")) (emit-image node path))
                ((equal tag "figure")
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (cl-loop
                  for image in (epub-reader-render--descendants node "img")
                  for image-index from 0
                  do (emit-image image
                                 (format "%s/image:%d" path image-index)))
                 (dolist (caption
                          (epub-reader-render--children node "figcaption"))
                   (emit 'paragraph caption
                         (epub-reader-render--normalize-inline
                          (epub-reader-render--inline caption node-language)
                          node-language)
                         (concat path "/caption"))))
                ((equal tag "table")
                 (emit 'code node
                       (epub-reader-render--table-text node node-language)
                       path))
                (t
                 (when (epub-reader-render--attribute node "id")
                   (emit 'anchor node "" path))
                 (if (cl-some
                      (lambda (child)
                        (and (stringp child)
                             (string-match-p "[^[:space:]]" child)))
                      (cddr node))
                     (emit-inline-runs (or (and (symbolp context) context)
                                           'paragraph)
                                       (node-without-id node) path
                                       node-language)
                   (walk-children node context path node-language)))))))
        (walk-children body nil "body" body-language))
    (nreverse blocks)))

(defun epub-reader-render-chapter (publication spine-index)
  "Load and return semantic blocks at PUBLICATION's SPINE-INDEX."
  (epub-reader-render-section
   publication
   (epub-reader-publication-load-section publication spine-index)))

(defun epub-reader-render--text-element (value)
  "Return a width-aware TextUI prose element for VALUE."
  (list :type :text :value value :wrap epub-reader-text-wrap-strategy
        :layout '(:min-width 20 :grow 1)))

(defun epub-reader-render--apply-highlights (text highlights)
  "Apply HIGHLIGHTS to source-attributed TEXT and return it.
Each highlight is a plist with :start, exclusive :end, :id, :quality, and
optional :note."
  (dolist (highlight highlights text)
    (let* ((start (max 0 (plist-get highlight :start)))
           (end (min (length text) (plist-get highlight :end)))
           (id (plist-get highlight :id))
           (quality (plist-get highlight :quality))
           (face (if (eq quality 'exact)
                     'epub-reader-highlight-face
                   'epub-reader-highlight-degraded-face)))
      (when (< start end)
        (add-face-text-property start end face nil text)
        (dotimes (delta (- end start))
          (let* ((position (+ start delta))
                 (ids (get-text-property
                       position 'epub-reader-annotation-ids text)))
            (add-text-properties
             position (1+ position)
             (list 'epub-reader-annotation-ids
                   (cl-adjoin id ids :test #'equal)
                   'epub-reader-annotation-quality quality
                   'help-echo
                   (if (eq quality 'exact)
                       (if (string-empty-p (or (plist-get highlight :note) ""))
                           "EPUB highlight"
                         (format "EPUB note: %s" (plist-get highlight :note)))
                     "EPUB highlight relocated from its quoted text"))
             text)))))))

(defun epub-reader-render--materialized-text (block &optional highlights)
  "Return a source-attributed copy of canonical BLOCK text with HIGHLIGHTS."
  (epub-reader-render--apply-highlights
   (epub-reader-locator-attach-source
    (epub-reader-block-text block)
    (epub-reader-block-document-path block)
    (epub-reader-block-key block)
    (epub-reader-block-book-key block)
    (epub-reader-block-spine-index block))
   highlights))

(defun epub-reader-render-materialize-image (block publication section)
  "Materialize BLOCK's image from PUBLICATION relative to SECTION.
Cache either the local file or a visible diagnostic on BLOCK."
  (when (and (eq (epub-reader-block-kind block) 'image)
             (epub-reader-block-image-href block)
             (not (epub-reader-block-image-file block))
             (not (epub-reader-block-image-error block)))
    (condition-case error-data
        (let ((target
               (epub-reader-publication-resolve-resource
                publication section (epub-reader-block-image-href block))))
          (cond
           ((epub-reader-link-target-external-p target)
            (setf (epub-reader-block-image-error block)
                  (format "Remote image is unsupported: %s"
                          (epub-reader-block-image-href block))))
           ((not (file-readable-p (epub-reader-link-target-file target)))
            (setf (epub-reader-block-image-error block)
                  (format "Image resource is unreadable: %s"
                          (epub-reader-block-image-href block))))
           (t
            (setf (epub-reader-block-image-file block)
                  (epub-reader-link-target-file target)))))
      (epub-reader-publication-resource-busy
       ;; Busy is transient coordination, not corrupt image data.  Let the
       ;; current frame fail cleanly so a later refresh can reuse the winner's
       ;; cache instead of freezing a permanent diagnostic onto BLOCK.
       (signal (car error-data) (cdr error-data)))
      (error
       (setf (epub-reader-block-image-error block)
             (format "Image error for %s: %s"
                     (epub-reader-block-image-href block)
                     (error-message-string error-data))))))
  block)

(defun epub-reader-render-block-element
    (block &optional publication section image-rows defer-image highlights)
  "Convert semantic BLOCK to one public TextUI element.
When PUBLICATION and SECTION are supplied, materialize an image block just
before producing its leaf unless DEFER-IMAGE is non-nil.  IMAGE-ROWS overrides
the configured image row budget when the UI has a buffer-specific font metric.
HIGHLIGHTS are source-offset spans for this block."
  (when (and publication section (not defer-image))
    (epub-reader-render-materialize-image block publication section))
  (let ((text (epub-reader-render--materialized-text block highlights)))
    (pcase (epub-reader-block-kind block)
    ('quote
     (list :type :flex :direction :column :border t :padding 1
           :children
           (list (epub-reader-render--text-element text))))
    ('code
     (list :type :flex :direction :column :border t :padding 1
           :children
           (list (epub-reader-render--text-element text))))
    ('list-item
     (epub-reader-render--text-element
      (concat (or (epub-reader-block-list-marker block) "• ")
              text)))
    ('image
     (let* ((rows (or image-rows epub-reader-image-rows))
            (source
             (get-text-property 0 'epub-reader-source text))
            (book-key
             (get-text-property 0 'epub-reader-book-key text))
            (spine-index
             (get-text-property 0 'epub-reader-spine-index text))
            (image-alt (copy-sequence text))
            (_image-anchor
             (when source
               (put-text-property
                0 (length image-alt) 'epub-reader-image-anchor
                (list source rows book-key spine-index)
                image-alt)))
            (caption (epub-reader-render--text-element text))
            (diagnostic
             (and (epub-reader-block-image-error block)
                  (epub-reader-render--text-element
                   (propertize
                    (format "[%s]"
                            (epub-reader-block-image-error block))
                    'face 'epub-reader-image-error-face)))))
       (cond
        ((epub-reader-block-image-file block)
         (list :type :flex :direction :column :gap 0
               :children
               (list
                (list :type :image
                      :file (epub-reader-block-image-file block)
                      :rows rows
                      :alt image-alt
                      :layout '(:min-width 12 :grow 1))
                caption)))
        (diagnostic
         (list :type :flex :direction :column :gap 0
               :children (list caption diagnostic)))
        ((epub-reader-block-image-href block)
         ;; Keep final image geometry while lifecycle-bound idle work extracts
         ;; the member.  TextUI renders an unreadable file as a fixed-row alt.
         (list :type :flex :direction :column :gap 0
               :children
               (list
                (list :type :image :file epub-reader-render--pending-image-file
                      :rows rows :alt image-alt
                      :layout '(:min-width 12 :grow 1))
                caption)))
        (t caption))))
    (_ (epub-reader-render--text-element text)))))

(defun epub-reader-render-blocks
    (blocks &optional publication section image-rows)
  "Convert semantic BLOCKS to public TextUI elements.
Optional PUBLICATION and SECTION enable on-demand image materialization.
IMAGE-ROWS is forwarded to every image leaf."
  (mapcar (lambda (block)
            (epub-reader-render-block-element
             block publication section image-rows))
          blocks))

(provide 'epub-reader-render)
;;; epub-reader-render.el ends here
