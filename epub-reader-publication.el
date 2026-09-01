;;; epub-reader-publication.el --- EPUB publication model -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Parse OCF, OPF, EPUB 2 NCX, and EPUB 3 navigation documents into one
;; publication model.  All paths stored in the model are archive-root-relative.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xml)
(require 'url-util)
(require 'epub-reader-container)

(define-error 'epub-reader-publication-error
  "Invalid EPUB publication" 'epub-reader-error)

(cl-defstruct (epub-reader-resource
               (:constructor epub-reader-resource--create))
  "One OPF manifest resource."
  id href path file media-type properties)

(cl-defstruct (epub-reader-spine-item
               (:constructor epub-reader-spine-item--create))
  "One ordered OPF spine reference."
  idref resource linear-p properties)

(cl-defstruct (epub-reader-toc-entry
               (:constructor epub-reader-toc-entry--create))
  "One EPUB 2 or EPUB 3 table-of-contents entry."
  label path fragment children)

(cl-defstruct (epub-reader-link-target
               (:constructor epub-reader-link-target--create))
  "A resolved internal or external hyperlink."
  external-p uri path file fragment)

(cl-defstruct (epub-reader-publication
               (:constructor epub-reader-publication--create))
  "A normalized EPUB publication owned by the caller."
  container version title language identifier opf-path opf-directory
  manifest spine toc closed-p)

(defun epub-reader-publication--local-name (name)
  "Return namespace-independent local name of symbol NAME."
  (let ((string (symbol-name name)))
    (if (string-match "\\([^:]+\\)\\'" string)
        (match-string 1 string)
      string)))

(defun epub-reader-publication--element-p (object)
  "Return non-nil when OBJECT is an XML element node."
  (and (consp object) (symbolp (car object))))

(defun epub-reader-publication--children (node &optional name)
  "Return NODE's direct element children, optionally matching local NAME."
  (cl-remove-if-not
   (lambda (child)
     (and (epub-reader-publication--element-p child)
          (or (null name)
              (equal (epub-reader-publication--local-name (car child))
                     name))))
   (cddr node)))

(defun epub-reader-publication--descendants (node name)
  "Return all descendant elements of NODE with local NAME."
  (cl-mapcan
   (lambda (child)
     (append
      (when (equal (epub-reader-publication--local-name (car child)) name)
        (list child))
      (epub-reader-publication--descendants child name)))
   (epub-reader-publication--children node)))

(defun epub-reader-publication--child (node name)
  "Return NODE's first direct child with local NAME."
  (car (epub-reader-publication--children node name)))

(defun epub-reader-publication--descendant (node name)
  "Return NODE's first descendant element with local NAME."
  (car (epub-reader-publication--descendants node name)))

(defun epub-reader-publication--attribute (node name)
  "Return NODE attribute whose local name is NAME."
  (cdr
   (cl-find-if
    (lambda (attribute)
      (equal (epub-reader-publication--local-name (car attribute)) name))
    (cadr node))))

(defun epub-reader-publication--text (node)
  "Return concatenated descendant text of NODE."
  (string-trim
   (mapconcat
    (lambda (child)
      (cond
       ((stringp child) child)
       ((epub-reader-publication--element-p child)
        (epub-reader-publication--text child))
       (t "")))
    (cddr node) "")))

(defun epub-reader-publication--parse-file (file)
  "Parse XML FILE and return its root element."
  (condition-case error-data
      (with-temp-buffer
        (insert-file-contents file)
        (or (car (xml-parse-region (point-min) (point-max)))
            (signal 'epub-reader-publication-error
                    (list (format "Empty XML document: %s" file)))))
    (epub-reader-publication-error
     (signal (car error-data) (cdr error-data)))
    (error
     (signal 'epub-reader-publication-error
             (list (format "Could not parse XML %s: %s"
                           file (error-message-string error-data)))))))

(defun epub-reader-publication--decode-component (string)
  "Percent-decode UTF-8 STRING used by an EPUB href."
  (decode-coding-string (url-unhex-string string) 'utf-8 t))

(defun epub-reader-publication--split-href (href)
  "Return decoded (PATH FRAGMENT) from local HREF, excluding its query."
  (let* ((hash (string-match "#" href))
         (raw-path (if hash (substring href 0 hash) href))
         (raw-fragment (and hash (substring href (1+ hash))))
         (query (string-match "?" raw-path)))
    (list (epub-reader-publication--decode-component
           (if query (substring raw-path 0 query) raw-path))
          (and raw-fragment
               (epub-reader-publication--decode-component raw-fragment)))))

(defun epub-reader-publication--external-href-p (href)
  "Return non-nil when HREF denotes an external URI."
  (or (string-prefix-p "//" href)
      (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" href)))

(defun epub-reader-publication--normalize-path (base-directory path)
  "Resolve decoded PATH below archive BASE-DIRECTORY without escaping root."
  (when (or (file-name-absolute-p path)
            (string-prefix-p "~" path)
            (string-match-p "\\`[[:alpha:]]:" path)
            (string-match-p "[\\\\\0\r\n]" path))
    (signal 'epub-reader-publication-error
            (list (format "Unsafe publication href: %S" path))))
  (let ((components
         (append (split-string (directory-file-name base-directory) "/" t)
                 (split-string path "/" nil)))
        stack)
    (dolist (component components)
      (cond
       ((member component '("" ".")))
       ((equal component "..")
        (if stack
            (pop stack)
          (signal 'epub-reader-publication-error
                  (list (format "Publication href escapes archive: %S"
                                path)))))
       (t (push component stack))))
    (mapconcat #'identity (nreverse stack) "/")))

(defun epub-reader-publication-resolve-href (publication base-path href)
  "Resolve HREF against archive-relative document BASE-PATH in PUBLICATION."
  (if (epub-reader-publication--external-href-p href)
      (epub-reader-link-target--create :external-p t :uri href)
    (pcase-let* ((`(,href-path ,fragment)
                  (epub-reader-publication--split-href href))
                 (effective-path
                  (if (string-empty-p href-path)
                      base-path
                    (epub-reader-publication--normalize-path
                     (or (file-name-directory base-path) "") href-path))))
      (epub-reader-link-target--create
       :external-p nil
       :path effective-path
       :file (epub-reader-container-path
              (epub-reader-publication-container publication) effective-path)
       :fragment fragment))))

(defun epub-reader-publication--required-attribute (node name context)
  "Return NODE attribute NAME or signal an error naming CONTEXT."
  (or (epub-reader-publication--attribute node name)
      (signal 'epub-reader-publication-error
              (list (format "%s has no %s attribute" context name)))))

(defun epub-reader-publication--package-path (container)
  "Return the OPF package path declared by CONTAINER."
  (let* ((container-path
          (epub-reader-container-path container "META-INF/container.xml")))
    (unless (file-readable-p container-path)
      (signal 'epub-reader-publication-error
              '("EPUB has no META-INF/container.xml")))
    (let* ((root (epub-reader-publication--parse-file container-path))
           (rootfile (epub-reader-publication--descendant root "rootfile"))
           (path (and rootfile
                      (epub-reader-publication--attribute rootfile
                                                          "full-path"))))
      (unless path
        (signal 'epub-reader-publication-error
                '("EPUB container has no package rootfile")))
      (epub-reader-publication--normalize-path "" path))))

(defun epub-reader-publication--metadata-text (metadata name)
  "Return first metadata descendant NAME text, or nil."
  (let ((node (and metadata
                   (epub-reader-publication--descendant metadata name))))
    (and node (epub-reader-publication--text node))))

(defun epub-reader-publication--properties (string)
  "Split an OPF space-separated property STRING."
  (and string (split-string string "[[:space:]]+" t)))

(defun epub-reader-publication--manifest
    (publication package package-directory)
  "Parse PACKAGE manifest relative to PACKAGE-DIRECTORY for PUBLICATION."
  (let ((manifest (epub-reader-publication--child package "manifest"))
        (table (make-hash-table :test #'equal)))
    (unless manifest
      (signal 'epub-reader-publication-error '("OPF has no manifest")))
    (dolist (item (epub-reader-publication--children manifest "item"))
      (let* ((id (epub-reader-publication--required-attribute
                  item "id" "Manifest item"))
             (href (epub-reader-publication--required-attribute
                    item "href" "Manifest item"))
             (path (epub-reader-publication--normalize-path
                    package-directory
                    (car (epub-reader-publication--split-href href)))))
        (when (gethash id table)
          (signal 'epub-reader-publication-error
                  (list (format "Duplicate manifest id: %s" id))))
        (puthash
         id
         (epub-reader-resource--create
          :id id :href href :path path
          :file (epub-reader-container-path
                 (epub-reader-publication-container publication) path)
          :media-type (epub-reader-publication--attribute item "media-type")
          :properties (epub-reader-publication--properties
                       (epub-reader-publication--attribute item "properties")))
         table)))
    table))

(defun epub-reader-publication--spine (package manifest)
  "Parse PACKAGE spine using MANIFEST and return an ordered vector."
  (let ((spine (epub-reader-publication--child package "spine"))
        items)
    (unless spine
      (signal 'epub-reader-publication-error '("OPF has no spine")))
    (dolist (itemref (epub-reader-publication--children spine "itemref"))
      (let* ((idref (epub-reader-publication--required-attribute
                     itemref "idref" "Spine item"))
             (resource (gethash idref manifest)))
        (unless resource
          (signal 'epub-reader-publication-error
                  (list (format "Spine references unknown manifest id: %s"
                                idref))))
        (unless (file-readable-p (epub-reader-resource-file resource))
          (signal 'epub-reader-publication-error
                  (list (format "Spine resource is missing: %s"
                                (epub-reader-resource-path resource)))))
        (push
         (epub-reader-spine-item--create
          :idref idref :resource resource
          :linear-p (not (equal
                          (epub-reader-publication--attribute itemref "linear")
                          "no"))
          :properties (epub-reader-publication--properties
                       (epub-reader-publication--attribute itemref
                                                           "properties")))
         items)))
    (vconcat (nreverse items))))

(defun epub-reader-publication--toc-target (publication base-path href)
  "Resolve TOC HREF against BASE-PATH in PUBLICATION."
  (let ((target
         (epub-reader-publication-resolve-href publication base-path href)))
    (unless (epub-reader-link-target-external-p target)
      (list (epub-reader-link-target-path target)
            (epub-reader-link-target-fragment target)))))

(defun epub-reader-publication--ncx-point (publication base-path nav-point)
  "Convert NCX NAV-POINT into a normalized TOC entry."
  (let* ((label-node
          (epub-reader-publication--descendant
           (epub-reader-publication--child nav-point "navLabel") "text"))
         (content (epub-reader-publication--child nav-point "content"))
         (href (and content
                    (epub-reader-publication--attribute content "src")))
         (target (and href
                      (epub-reader-publication--toc-target
                       publication base-path href))))
    (when (and label-node target)
      (epub-reader-toc-entry--create
       :label (epub-reader-publication--text label-node)
       :path (car target) :fragment (cadr target)
       :children
       (delq nil
             (mapcar
              (lambda (child)
                (epub-reader-publication--ncx-point
                 publication base-path child))
              (epub-reader-publication--children nav-point "navPoint")))))))

(defun epub-reader-publication--ncx-toc (publication package manifest)
  "Return EPUB 2 NCX TOC from PACKAGE and MANIFEST."
  (let* ((spine (epub-reader-publication--child package "spine"))
         (toc-id (and spine
                      (epub-reader-publication--attribute spine "toc")))
         (resource (and toc-id (gethash toc-id manifest))))
    (when (and resource (file-readable-p (epub-reader-resource-file resource)))
      (let* ((root (epub-reader-publication--parse-file
                    (epub-reader-resource-file resource)))
             (nav-map (epub-reader-publication--descendant root "navMap")))
        (delq nil
              (mapcar
               (lambda (point)
                 (epub-reader-publication--ncx-point
                  publication (epub-reader-resource-path resource) point))
               (epub-reader-publication--children nav-map "navPoint")))))))

(defun epub-reader-publication--nav-li (publication base-path li)
  "Convert EPUB 3 navigation LI relative to BASE-PATH into a TOC entry."
  (let* ((anchor (epub-reader-publication--child li "a"))
         (label-node (or anchor (epub-reader-publication--child li "span")))
         (href (and anchor
                    (epub-reader-publication--attribute anchor "href")))
         (target (and href
                      (epub-reader-publication--toc-target
                       publication base-path href)))
         (nested (epub-reader-publication--child li "ol")))
    (when (and label-node target)
      (epub-reader-toc-entry--create
       :label (epub-reader-publication--text label-node)
       :path (car target) :fragment (cadr target)
       :children
       (delq nil
             (mapcar
              (lambda (child)
                (epub-reader-publication--nav-li
                 publication base-path child))
              (epub-reader-publication--children nested "li")))))))

(defun epub-reader-publication--nav-toc (publication manifest)
  "Return EPUB 3 navigation TOC declared in MANIFEST."
  (let (nav-resource)
    (maphash
     (lambda (_id resource)
       (when (member "nav" (epub-reader-resource-properties resource))
         (setq nav-resource resource)))
     manifest)
    (when (and nav-resource
               (file-readable-p (epub-reader-resource-file nav-resource)))
      (let* ((root (epub-reader-publication--parse-file
                    (epub-reader-resource-file nav-resource)))
             (nav
              (cl-find-if
               (lambda (candidate)
                 (member "toc"
                         (epub-reader-publication--properties
                          (epub-reader-publication--attribute candidate
                                                              "type"))))
               (epub-reader-publication--descendants root "nav")))
             (list-node (and nav
                             (epub-reader-publication--child nav "ol"))))
        (delq nil
              (mapcar
               (lambda (li)
                 (epub-reader-publication--nav-li
                  publication (epub-reader-resource-path nav-resource) li))
               (epub-reader-publication--children list-node "li")))))))

(defun epub-reader-publication--check-mimetype (container)
  "Require the canonical EPUB mimetype member in CONTAINER."
  (let ((file (epub-reader-container-path container "mimetype")))
    (unless (and (file-readable-p file)
                 (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally file)
                   (equal (buffer-string) "application/epub+zip")))
      (signal 'epub-reader-publication-error
              '("Archive does not contain the EPUB mimetype")))))

(defun epub-reader-publication--from-container (container)
  "Parse live CONTAINER and return a publication owning it."
  (epub-reader-publication--check-mimetype container)
  (let* ((opf-path (epub-reader-publication--package-path container))
         (opf-file (epub-reader-container-path container opf-path)))
    (unless (file-readable-p opf-file)
      (signal 'epub-reader-publication-error
              (list (format "Package document is missing: %s" opf-path))))
    (let* ((package (epub-reader-publication--parse-file opf-file))
           (metadata (epub-reader-publication--child package "metadata"))
           (publication
            (epub-reader-publication--create
             :container container
             :version (or (epub-reader-publication--attribute
                           package "version") "")
             :title (or (epub-reader-publication--metadata-text
                         metadata "title")
                        (file-name-base
                         (epub-reader-container-source container)))
             :language (epub-reader-publication--metadata-text
                        metadata "language")
             :identifier (epub-reader-publication--metadata-text
                          metadata "identifier")
             :opf-path opf-path
             :opf-directory (or (file-name-directory opf-path) "")
             :closed-p nil))
           (manifest
            (epub-reader-publication--manifest
             publication package
             (epub-reader-publication-opf-directory publication)))
           (spine (epub-reader-publication--spine package manifest)))
      (setf (epub-reader-publication-manifest publication) manifest
            (epub-reader-publication-spine publication) spine
            (epub-reader-publication-toc publication)
            (or (epub-reader-publication--nav-toc publication manifest)
                (epub-reader-publication--ncx-toc
                 publication package manifest)))
      publication)))

;;;###autoload
(defun epub-reader-publication-open (file)
  "Open EPUB FILE and return a normalized `epub-reader-publication'."
  (let ((container (epub-reader-container-open file))
        succeeded)
    (unwind-protect
        (prog1 (epub-reader-publication--from-container container)
          (setq succeeded t))
      (unless succeeded
        (epub-reader-container-close container)))))

(defun epub-reader-publication-close (publication)
  "Close PUBLICATION and release its extracted container; idempotent."
  (unless (epub-reader-publication-closed-p publication)
    (setf (epub-reader-publication-closed-p publication) t)
    (epub-reader-container-close
     (epub-reader-publication-container publication)))
  nil)

(defun epub-reader-publication-spine-resource (publication index)
  "Return PUBLICATION spine resource at zero-based INDEX."
  (let ((item (and (>= index 0)
                   (< index (length
                             (epub-reader-publication-spine publication)))
                   (aref (epub-reader-publication-spine publication) index))))
    (and item (epub-reader-spine-item-resource item))))

(provide 'epub-reader-publication)
;;; epub-reader-publication.el ends here
