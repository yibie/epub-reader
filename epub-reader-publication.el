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
(require 'url-parse)
(require 'epub-reader-container)

(define-error 'epub-reader-publication-error
  "Invalid EPUB publication" 'epub-reader-error)

(defcustom epub-reader-external-link-schemes '("http" "https" "mailto")
  "External URI schemes that publication links may activate."
  :type '(repeat string)
  :group 'epub-reader)

(cl-defstruct (epub-reader-resource
               (:constructor epub-reader-resource--create))
  "One OPF manifest resource."
  id href path file size uri remote-p media-type properties)

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
  external-p uri path file fragment resource-key)

(cl-defstruct (epub-reader-section
               (:constructor epub-reader-section--create))
  "One parsed spine section with its effective resource base."
  spine-index resource path base-path document)

(cl-defstruct (epub-reader-publication
               (:constructor epub-reader-publication--create))
  "A normalized EPUB publication owned by the caller."
  container version title language identifier book-key opf-path opf-directory
  manifest spine toc closed-p)

(defun epub-reader-publication--content-hash (file)
  "Return a SHA-256 digest of FILE's literal bytes.

This is called once while constructing a publication; the resulting book key
is then retained on the publication object."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun epub-reader-publication--book-key (container identifier)
  "Return a durable identity for CONTAINER, with IDENTIFIER as a hint only."
  (let* ((source (file-truename (epub-reader-container-source container)))
         ;; Identity bytes and metadata come from the immutable archive
         ;; snapshot that was preflighted.  The canonical external path remains
         ;; part of the key so moving a book still creates an independent
         ;; reading identity, as documented by the locator contract.
         (archive (epub-reader-container-archive container))
         (attributes (file-attributes archive 'string))
         (size (file-attribute-size attributes))
         (mtime (file-attribute-modification-time attributes))
         (content-hash (epub-reader-publication--content-hash archive))
         (identity
          (prin1-to-string
           (list :format 1 :identifier identifier :path source
                 :size size :mtime mtime :content-hash content-hash))))
    (concat "epub-reader-book-v1:" (secure-hash 'sha256 identity))))

(defconst epub-reader-publication--ocf-namespace
  "urn:oasis:names:tc:opendocument:xmlns:container")
(defconst epub-reader-publication--opf-namespace
  "http://www.idpf.org/2007/opf")
(defconst epub-reader-publication--dc-namespace
  "http://purl.org/dc/elements/1.1/")
(defconst epub-reader-publication--ncx-namespace
  "http://www.daisy.org/z3986/2005/ncx/")
(defconst epub-reader-publication--xhtml-namespace
  "http://www.w3.org/1999/xhtml")
(defconst epub-reader-publication--ops-namespace
  "http://www.idpf.org/2007/ops")

(defun epub-reader-publication--local-name (name)
  "Return the local part of expanded XML qualified NAME."
  (if (consp name) (cdr name) (symbol-name name)))

(defun epub-reader-publication--namespace (name)
  "Return namespace URI of expanded XML qualified NAME."
  (if (consp name) (car name) ""))

(defun epub-reader-publication--qname-p (name namespace local-name)
  "Return non-nil when NAME is NAMESPACE plus LOCAL-NAME."
  (and (equal (epub-reader-publication--namespace name) namespace)
       (equal (epub-reader-publication--local-name name) local-name)))

(defun epub-reader-publication--element-p (object)
  "Return non-nil when OBJECT is an XML element node."
  (and (consp object)
       (let ((name (car object)))
         (or (symbolp name)
             (and (consp name) (stringp (car name))
                  (stringp (cdr name)))))))

(defun epub-reader-publication--children (node &optional name namespace)
  "Return NODE's direct children matching NAME and NAMESPACE.
When NAMESPACE is omitted, inherit NODE's namespace."
  (let ((expected-namespace
         (or namespace (epub-reader-publication--namespace (car node)))))
  (cl-remove-if-not
   (lambda (child)
     (and (epub-reader-publication--element-p child)
          (or (null name)
              (epub-reader-publication--qname-p
               (car child) expected-namespace name))))
   (cddr node))))

(defun epub-reader-publication--descendants (node name &optional namespace)
  "Return NODE descendants matching NAME and NAMESPACE."
  (let ((expected-namespace
         (or namespace (epub-reader-publication--namespace (car node)))))
  (cl-mapcan
   (lambda (child)
     (append
      (when (epub-reader-publication--qname-p
             (car child) expected-namespace name)
        (list child))
      (epub-reader-publication--descendants
       child name expected-namespace)))
   (epub-reader-publication--children node nil
                                      (epub-reader-publication--namespace
                                       (car node))))))

(defun epub-reader-publication--child (node name &optional namespace)
  "Return NODE's first direct child matching NAME and NAMESPACE."
  (car (epub-reader-publication--children node name namespace)))

(defun epub-reader-publication--descendant (node name &optional namespace)
  "Return NODE's first descendant matching NAME and NAMESPACE."
  (car (epub-reader-publication--descendants node name namespace)))

(defun epub-reader-publication--attribute (node name &optional namespace)
  "Return NODE attribute matching NAME and NAMESPACE.
Unqualified attributes use the empty namespace."
  (cdr
   (cl-find-if
    (lambda (attribute)
      (epub-reader-publication--qname-p
       (car attribute) (or namespace "") name))
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
        (or (car (xml-parse-region (point-min) (point-max) nil nil t))
            (signal 'epub-reader-publication-error
                    (list (format "Empty XML document: %s" file)))))
    (epub-reader-publication-error
     (signal (car error-data) (cdr error-data)))
    (error
     (signal 'epub-reader-publication-error
             (list (format "Could not parse XML %s: %s"
                           file (error-message-string error-data)))))))

(defun epub-reader-publication--hex-byte (string offset)
  "Return strict percent byte in STRING at OFFSET or signal."
  (unless (and (< (+ offset 2) (length string))
               (= (aref string offset) ?%)
               (string-match-p
                "\\`[[:xdigit:]][[:xdigit:]]\\'"
                (substring string (1+ offset) (+ offset 3))))
    (signal 'epub-reader-publication-error
            (list (format "Invalid percent escape in href: %S" string))))
  (string-to-number (substring string (1+ offset) (+ offset 3)) 16))

(defun epub-reader-publication--decode-percent-run (bytes context)
  "Decode UTF-8 BYTES for href CONTEXT, rejecting malformed sequences."
  (cl-labels
      ((continuation-p (byte) (and (>= byte #x80) (<= byte #xbf)))
       (valid-p ()
         (let ((position 0) (length (length bytes)) valid)
           (setq valid t)
           (while (and valid (< position length))
             (let ((first (aref bytes position)))
               (cond
                ((<= first #x7f) (cl-incf position))
                ((and (>= first #xc2) (<= first #xdf)
                      (< (1+ position) length)
                      (continuation-p (aref bytes (1+ position))))
                 (cl-incf position 2))
                ((and (>= first #xe0) (<= first #xef)
                      (< (+ position 2) length)
                      (let ((second (aref bytes (1+ position))))
                        (and (continuation-p second)
                             (continuation-p (aref bytes (+ position 2)))
                             (or (/= first #xe0) (>= second #xa0))
                             (or (/= first #xed) (<= second #x9f)))))
                 (cl-incf position 3))
                ((and (>= first #xf0) (<= first #xf4)
                      (< (+ position 3) length)
                      (let ((second (aref bytes (1+ position))))
                        (and (continuation-p second)
                             (continuation-p (aref bytes (+ position 2)))
                             (continuation-p (aref bytes (+ position 3)))
                             (or (/= first #xf0) (>= second #x90))
                             (or (/= first #xf4) (<= second #x8f)))))
                 (cl-incf position 4))
                (t (setq valid nil)))))
           valid)))
    (unless (valid-p)
      (signal 'epub-reader-publication-error
              (list (format "Invalid UTF-8 percent escape in href: %S"
                            context))))
    (decode-coding-string bytes 'utf-8)))

(defun epub-reader-publication--decode-url-part
    (string &optional preserve-path-separators)
  "Strictly percent-decode STRING.
When PRESERVE-PATH-SEPARATORS is non-nil, keep encoded slash and backslash as
uppercase percent escapes so they cannot become path separators."
  (let ((position 0)
        (bytes (unibyte-string))
        (result ""))
    (cl-labels ((flush-bytes ()
                  (when (> (length bytes) 0)
                    (setq result
                          (concat result
                                  (epub-reader-publication--decode-percent-run
                                   bytes string))
                          bytes (unibyte-string)))))
      (while (< position (length string))
        (if (/= (aref string position) ?%)
            (progn
              (flush-bytes)
              (setq result (concat result
                                   (substring string position (1+ position)))
                    position (1+ position)))
          (let ((byte (epub-reader-publication--hex-byte string position)))
            (if (and preserve-path-separators (memq byte '(47 92)))
                (progn
                  (flush-bytes)
                  (setq result (concat result (format "%%%02X" byte))))
              (setq bytes (concat bytes (unibyte-string byte))))
            (setq position (+ position 3)))))
      (flush-bytes))
    result))

(defun epub-reader-publication--split-href (href)
  "Return raw (PATH FRAGMENT) from HREF, excluding its query."
  (let* ((hash (string-match "#" href))
         (before-fragment (if hash (substring href 0 hash) href))
         (fragment (and hash (substring href (1+ hash))))
         (query (string-match "?" before-fragment)))
    (list (if query (substring before-fragment 0 query) before-fragment)
          (and fragment
               (epub-reader-publication--decode-url-part fragment)))))

(defun epub-reader-publication--external-href-p (href)
  "Return non-nil when HREF denotes an external URI."
  (or (string-prefix-p "//" href)
      (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" href)))

(defun epub-reader-publication--canonicalize-percent-escapes (url)
  "Return URL with unreserved escapes decoded and other escapes uppercased."
  (let ((position 0)
        (length (length url))
        parts)
    (while (< position length)
      (if (/= (aref url position) ?%)
          (progn
            (push (substring url position (1+ position)) parts)
            (setq position (1+ position)))
        (let ((byte (epub-reader-publication--hex-byte url position)))
          (push (if (or (and (>= byte ?A) (<= byte ?Z))
                        (and (>= byte ?a) (<= byte ?z))
                        (and (>= byte ?0) (<= byte ?9))
                        (memq byte '(?- ?. ?_ ?~)))
                    (char-to-string byte)
                  (format "%%%02X" byte))
                parts)
          (setq position (+ position 3)))))
    (apply #'concat (nreverse parts))))

(defun epub-reader-publication--remove-last-url-segment (path)
  "Remove the last segment from RFC 3986 output PATH."
  (if (string-match "/[^/]*\\'" path)
      (substring path 0 (match-beginning 0))
    ""))

(defun epub-reader-publication--remove-dot-segments (path)
  "Remove dot segments from URL PATH according to RFC 3986 section 5.2.4."
  (let ((input path)
        (output ""))
    (while (not (string-empty-p input))
      (cond
       ((string-prefix-p "../" input)
        (setq input (substring input 3)))
       ((string-prefix-p "./" input)
        (setq input (substring input 2)))
       ((string-prefix-p "/./" input)
        (setq input (substring input 2)))
       ((equal input "/.")
        (setq input "/"))
       ((string-prefix-p "/../" input)
        (setq input (substring input 3)
              output
              (epub-reader-publication--remove-last-url-segment output)))
       ((equal input "/..")
        (setq input "/"
              output
              (epub-reader-publication--remove-last-url-segment output)))
       ((member input '("." ".."))
        (setq input ""))
       (t
        (let* ((search-start (if (string-prefix-p "/" input) 1 0))
               (next-slash (string-match "/" input search-start))
               (end (or next-slash (length input))))
          (setq output (concat output (substring input 0 end))
                input (substring input end))))))
    output))

(defun epub-reader-publication--normalize-external-url (parsed)
  "Return a canonical resource URL represented by PARSED.

For hierarchical URLs, percent-encoded unreserved characters are decoded
before RFC 3986 dot-segment removal.  The query remains part of the resource
key, but is not interpreted as a path."
  (let* ((filename (or (url-filename parsed) ""))
         (query-start (string-match "?" filename))
         (raw-path (if query-start
                       (substring filename 0 query-start)
                     filename))
         (query (and query-start (substring filename query-start)))
         (canonical-path
          (epub-reader-publication--canonicalize-percent-escapes raw-path)))
    (when (or (url-host parsed) (string-prefix-p "/" canonical-path))
      (setq canonical-path
            (epub-reader-publication--remove-dot-segments canonical-path)))
    (setf (url-filename parsed)
          (concat canonical-path
                  (if query
                      (epub-reader-publication--canonicalize-percent-escapes
                       query)
                    "")))
    (epub-reader-publication--canonicalize-percent-escapes
     (url-recreate-url parsed))))

(defun epub-reader-publication--external-target (href)
  "Parse external HREF into a normalized link target."
  (let* ((hash (string-match "#" href))
         (resource-uri (if hash (substring href 0 hash) href))
         (raw-fragment (and hash (substring href (1+ hash))))
         (_percent-check
          (epub-reader-publication--decode-url-part resource-uri t))
         (parsed
          (condition-case error-data
              (url-generic-parse-url resource-uri)
            (error
             (signal 'epub-reader-publication-error
                     (list (format "Invalid external URL %S: %s" href
                                   (error-message-string error-data)))))))
         (scheme (and (url-type parsed) (downcase (url-type parsed))))
         (_scheme-check
          (unless (member scheme epub-reader-external-link-schemes)
            (signal 'epub-reader-publication-error
                    (list (format "External URL scheme is not allowed: %S"
                                  (or scheme href))))))
         (canonical (epub-reader-publication--normalize-external-url parsed))
         (fragment
          (and raw-fragment
               (epub-reader-publication--decode-url-part raw-fragment))))
    (epub-reader-link-target--create
     :external-p t
     :uri (if raw-fragment
              (concat canonical "#"
                      (epub-reader-publication--canonicalize-percent-escapes
                       raw-fragment))
            canonical)
     :fragment fragment :resource-key canonical)))

(defun epub-reader-publication--normalize-url-path (base-path raw-path)
  "Resolve URL RAW-PATH against archive document BASE-PATH."
  (when (string-prefix-p "/" raw-path)
    (signal 'epub-reader-publication-error
            (list (format "OCF URL cannot be root-relative: %S" raw-path))))
  (let* ((directory-reference-p (string-suffix-p "/" raw-path))
         (path-for-splitting
          (if directory-reference-p
              (string-remove-suffix "/" raw-path)
            raw-path))
         (components
         (append
          (split-string
           (if (string-suffix-p "/" base-path)
               base-path
             (or (file-name-directory base-path) ""))
           "/" t)
          (mapcar
           (lambda (segment)
             (epub-reader-publication--decode-url-part segment t))
           (split-string
            path-for-splitting "/" nil))))
        stack)
    (dolist (component components)
      (cond
       ((equal component "."))
       ((string-empty-p component)
        (signal 'epub-reader-publication-error
                (list (format "Empty path segment in href: %S" raw-path))))
       ((equal component "..")
        (if stack
            (pop stack)
          (signal 'epub-reader-publication-error
                  (list (format "Publication href escapes archive: %S"
                                raw-path)))))
       (t (push component stack))))
    (let ((normalized (mapconcat #'identity (nreverse stack) "/")))
      (if directory-reference-p (concat normalized "/") normalized))))

(defun epub-reader-publication-resolve-href (publication base-path href)
  "Resolve HREF against archive-relative document BASE-PATH in PUBLICATION."
  (if (epub-reader-publication--external-href-p href)
      (epub-reader-publication--external-target href)
    (pcase-let* ((`(,raw-path ,fragment)
                  (epub-reader-publication--split-href href))
                 (effective-path
                  (if (string-empty-p raw-path)
                      base-path
                    (epub-reader-publication--normalize-url-path
                     base-path raw-path))))
      (epub-reader-link-target--create
       :external-p nil
       :path effective-path
       :file (epub-reader-container-path
              (epub-reader-publication-container publication) effective-path)
       :fragment fragment :resource-key effective-path))))

(defun epub-reader-publication--required-attribute (node name context)
  "Return NODE attribute NAME or signal an error naming CONTEXT."
  (let ((value (epub-reader-publication--attribute node name)))
    (if (and value
             (not (string-match-p "\\`[[:space:]]*\\'" value)))
        value
      (signal 'epub-reader-publication-error
              (list (format "%s has no non-empty %s attribute"
                            context name))))))

(defun epub-reader-publication--package-path (container)
  "Return the OPF package path declared by CONTAINER."
  (let* ((container-path
          (epub-reader-container-materialize-member
           container "META-INF/container.xml")))
    (unless (file-readable-p container-path)
      (signal 'epub-reader-publication-error
              '("EPUB has no META-INF/container.xml")))
    (let* ((root (epub-reader-publication--parse-file container-path))
           (_root-check
            (unless (epub-reader-publication--qname-p
                     (car root) epub-reader-publication--ocf-namespace
                     "container")
              (signal 'epub-reader-publication-error
                      '("OCF container root has the wrong namespace"))))
           (rootfiles
            (epub-reader-publication--child
             root "rootfiles" epub-reader-publication--ocf-namespace))
           (rootfile
            (cl-find-if
             (lambda (candidate)
               (equal
                (epub-reader-publication--attribute candidate "media-type")
                "application/oebps-package+xml"))
             (and rootfiles
                  (epub-reader-publication--children
                   rootfiles "rootfile"
                   epub-reader-publication--ocf-namespace))))
           (path (and rootfile
                      (epub-reader-publication--attribute
                       rootfile "full-path"))))
      (unless path
        (signal 'epub-reader-publication-error
                '("EPUB container has no supported package rootfile")))
      (pcase-let ((`(,raw-path ,fragment)
                   (epub-reader-publication--split-href path)))
        (when fragment
          (signal 'epub-reader-publication-error
                  '("Package rootfile cannot contain a fragment")))
        (epub-reader-publication--normalize-url-path "" raw-path)))))

(defun epub-reader-publication--metadata-text (metadata name)
  "Return first direct Dublin Core metadata NAME text, or nil."
  (let ((node (and metadata
                   (epub-reader-publication--child
                    metadata name epub-reader-publication--dc-namespace))))
    (and node (epub-reader-publication--text node))))

(defun epub-reader-publication--identifier (package metadata)
  "Return identifier selected by PACKAGE's unique-identifier IDREF."
  (let ((idref (epub-reader-publication--required-attribute
                package "unique-identifier" "Package")))
    (or
     (cl-loop
      for node in (epub-reader-publication--children
                   metadata "identifier" epub-reader-publication--dc-namespace)
      when (equal (epub-reader-publication--attribute node "id") idref)
      return (epub-reader-publication--text node))
     (signal 'epub-reader-publication-error
             (list (format "Package unique-identifier is unresolved: %s"
                           idref))))))

(defun epub-reader-publication--properties (string)
  "Split an OPF space-separated property STRING."
  (and string (split-string string "[[:space:]]+" t)))

(defun epub-reader-publication--manifest (publication package)
  "Parse PACKAGE manifest for PUBLICATION."
  (let ((manifest
         (epub-reader-publication--child
          package "manifest" epub-reader-publication--opf-namespace))
        (table (make-hash-table :test #'equal))
        (seen-urls (make-hash-table :test #'equal)))
    (unless manifest
      (signal 'epub-reader-publication-error '("OPF has no manifest")))
    (dolist (item
             (epub-reader-publication--children
              manifest "item" epub-reader-publication--opf-namespace))
      (let* ((id (epub-reader-publication--required-attribute
                  item "id" "Manifest item"))
             (href (epub-reader-publication--required-attribute
                    item "href" "Manifest item"))
             (media-type (epub-reader-publication--required-attribute
                          item "media-type" "Manifest item"))
             (target
              (epub-reader-publication-resolve-href
               publication (epub-reader-publication-opf-path publication)
               href))
             (remote-p (epub-reader-link-target-external-p target))
             (path (and (not remote-p)
                        (epub-reader-link-target-path target)))
             (url-key (if remote-p
                          (concat "remote:"
                                  (epub-reader-link-target-resource-key target))
                        (concat "local:" path))))
        (when (epub-reader-link-target-fragment target)
          (signal 'epub-reader-publication-error
                  (list (format "Manifest item URL has a fragment: %s" href))))
        (when (gethash id table)
          (signal 'epub-reader-publication-error
                  (list (format "Duplicate manifest id: %s" id))))
        (when (gethash url-key seen-urls)
          (signal 'epub-reader-publication-error
                  (list (format "Duplicate resolved manifest URL: %s" href))))
        (puthash url-key id seen-urls)
        (puthash
         id
         (epub-reader-resource--create
          :id id :href href :path path
          :file nil
          :size (and path
                     (epub-reader-container-member-p
                      (epub-reader-publication-container publication) path)
                     (epub-reader-container-member-size
                      (epub-reader-publication-container publication) path))
          :uri (and remote-p (epub-reader-link-target-uri target))
          :remote-p remote-p
          :media-type media-type
          :properties (epub-reader-publication--properties
                       (epub-reader-publication--attribute item "properties")))
         table)))
    table))

(defun epub-reader-publication--spine (publication package manifest)
  "Parse PACKAGE spine for PUBLICATION using MANIFEST."
  (let ((spine
         (epub-reader-publication--child
          package "spine" epub-reader-publication--opf-namespace))
        items)
    (unless spine
      (signal 'epub-reader-publication-error '("OPF has no spine")))
    (dolist (itemref
             (epub-reader-publication--children
              spine "itemref" epub-reader-publication--opf-namespace))
      (let* ((idref (epub-reader-publication--required-attribute
                     itemref "idref" "Spine item"))
             (resource (gethash idref manifest)))
        (unless resource
          (signal 'epub-reader-publication-error
                  (list (format "Spine references unknown manifest id: %s"
                                idref))))
        (when (epub-reader-resource-remote-p resource)
          (signal 'epub-reader-publication-error
                  (list (format "Remote spine resources are unsupported: %s"
                                (epub-reader-resource-uri resource)))))
        (unless (epub-reader-container-member-p
                 (epub-reader-publication-container publication)
                 (epub-reader-resource-path resource))
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
    (unless items
      (signal 'epub-reader-publication-error '("OPF spine is empty")))
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
           (epub-reader-publication--child
            nav-point "navLabel" epub-reader-publication--ncx-namespace)
           "text" epub-reader-publication--ncx-namespace))
         (content
          (epub-reader-publication--child
           nav-point "content" epub-reader-publication--ncx-namespace))
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
              (epub-reader-publication--children
               nav-point "navPoint"
               epub-reader-publication--ncx-namespace)))))))

(defun epub-reader-publication--ncx-toc (publication package manifest)
  "Return EPUB 2 NCX TOC from PACKAGE and MANIFEST."
  (let* ((spine
          (epub-reader-publication--child
           package "spine" epub-reader-publication--opf-namespace))
         (toc-id (and spine
                      (epub-reader-publication--attribute spine "toc")))
         (resource (and toc-id (gethash toc-id manifest))))
    (let ((file (and resource
                     (epub-reader-publication--materialize-manifest-resource
                      publication resource))))
      (when file
        (let* ((root (epub-reader-publication--parse-file file))
             (nav-map
              (and (epub-reader-publication--qname-p
                    (car root) epub-reader-publication--ncx-namespace "ncx")
                   (epub-reader-publication--descendant
                    root "navMap" epub-reader-publication--ncx-namespace))))
        (delq nil
              (mapcar
               (lambda (point)
                 (epub-reader-publication--ncx-point
                  publication (epub-reader-resource-path resource) point))
               (epub-reader-publication--children
                nav-map "navPoint"
                epub-reader-publication--ncx-namespace))))))))

(defun epub-reader-publication--nav-label (node)
  "Return accessible label text for EPUB navigation NODE."
  (let ((text (epub-reader-publication--text node)))
    (if (not (string-empty-p text))
        text
      (or (epub-reader-publication--attribute node "title")
          (let ((image
                 (epub-reader-publication--descendant
                  node "img" epub-reader-publication--xhtml-namespace)))
            (and image (epub-reader-publication--attribute image "alt")))))))

(defun epub-reader-publication--nav-li (publication base-path li)
  "Convert EPUB 3 navigation LI relative to BASE-PATH into a TOC entry."
  (let* ((anchor
          (epub-reader-publication--child
           li "a" epub-reader-publication--xhtml-namespace))
         (label-node
          (or anchor
              (epub-reader-publication--child
               li "span" epub-reader-publication--xhtml-namespace)))
         (href (and anchor
                    (epub-reader-publication--attribute anchor "href")))
         (target (and href
                      (epub-reader-publication--toc-target
                       publication base-path href)))
         (nested
          (epub-reader-publication--child
           li "ol" epub-reader-publication--xhtml-namespace))
         (children
          (delq nil
                (mapcar
                 (lambda (child)
                   (epub-reader-publication--nav-li
                    publication base-path child))
                 (and nested
                      (epub-reader-publication--children
                       nested "li"
                       epub-reader-publication--xhtml-namespace))))))
    (when (and label-node (or target children))
      (epub-reader-toc-entry--create
       :label (or (epub-reader-publication--nav-label label-node) "")
       :path (car target) :fragment (cadr target) :children children))))

(defun epub-reader-publication--nav-toc (publication manifest)
  "Return EPUB 3 navigation TOC declared in MANIFEST."
  (let (nav-resource)
    (maphash
     (lambda (_id resource)
       (when (member "nav" (epub-reader-resource-properties resource))
         (setq nav-resource resource)))
     manifest)
    (let ((file (and nav-resource
                     (epub-reader-publication--materialize-manifest-resource
                      publication nav-resource))))
      (when file
        (let* ((root (epub-reader-publication--parse-file file))
             (nav
              (cl-find-if
               (lambda (candidate)
                 (member "toc"
                         (epub-reader-publication--properties
                          (epub-reader-publication--attribute
                           candidate "type"
                           epub-reader-publication--ops-namespace))))
               (epub-reader-publication--descendants
                root "nav" epub-reader-publication--xhtml-namespace)))
             (list-node (and nav
                             (epub-reader-publication--child
                              nav "ol"
                              epub-reader-publication--xhtml-namespace))))
        (delq nil
              (mapcar
               (lambda (li)
                 (epub-reader-publication--nav-li
                  publication (epub-reader-resource-path nav-resource) li))
               (epub-reader-publication--children
                list-node "li"
                epub-reader-publication--xhtml-namespace))))))))

(defun epub-reader-publication--materialize-manifest-resource
    (publication resource)
  "Materialize local manifest RESOURCE in PUBLICATION, or return nil."
  (when (and resource
             (not (epub-reader-resource-remote-p resource))
             (epub-reader-container-member-p
              (epub-reader-publication-container publication)
              (epub-reader-resource-path resource)))
    (let ((file
           (epub-reader-container-materialize-member
            (epub-reader-publication-container publication)
            (epub-reader-resource-path resource))))
      (setf (epub-reader-resource-file resource) file)
      file)))

(defun epub-reader-publication--check-mimetype (container)
  "Require the canonical EPUB mimetype member in CONTAINER."
  (let ((file
         (epub-reader-container-materialize-member container "mimetype")))
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
         (opf-file
          (epub-reader-container-materialize-member container opf-path)))
    (unless (file-readable-p opf-file)
      (signal 'epub-reader-publication-error
              (list (format "Package document is missing: %s" opf-path))))
    (let* ((package (epub-reader-publication--parse-file opf-file))
           (_package-check
            (unless (epub-reader-publication--qname-p
                     (car package) epub-reader-publication--opf-namespace
                     "package")
              (signal 'epub-reader-publication-error
                      '("Package document has the wrong namespace"))))
           (version (epub-reader-publication--required-attribute
                     package "version" "Package"))
           (_version-check
            (unless (member version '("2.0" "3.0"))
              (signal 'epub-reader-publication-error
                      (list (format "Unsupported package version: %s"
                                    version)))))
           (metadata
            (epub-reader-publication--child
             package "metadata" epub-reader-publication--opf-namespace))
           (_metadata-check
            (unless metadata
              (signal 'epub-reader-publication-error
                      '("OPF has no metadata"))))
           (title (epub-reader-publication--metadata-text metadata "title"))
           (language
            (epub-reader-publication--metadata-text metadata "language"))
           (identifier
            (epub-reader-publication--identifier package metadata))
           (_required-metadata-check
            (unless (and title (not (string-empty-p title))
                         language (not (string-empty-p language))
                         identifier (not (string-empty-p identifier)))
              (signal 'epub-reader-publication-error
                      '("OPF requires title, language, and identifier"))))
           (book-key
            (epub-reader-publication--book-key container identifier))
           (publication
            (epub-reader-publication--create
             :container container
             :version version :title title :language language
             :identifier identifier :book-key book-key
             :opf-path opf-path
             :opf-directory (or (file-name-directory opf-path) "")
             :closed-p nil))
           (manifest
            (epub-reader-publication--manifest publication package))
           (spine
            (epub-reader-publication--spine publication package manifest)))
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
        ;; Preserve the parsing/opening error; no publication handle exists
        ;; through which the caller could retry this best-effort cleanup.
        (ignore-errors (epub-reader-container-close container))))))

(defun epub-reader-publication-close (publication)
  "Close PUBLICATION and release its extracted container; idempotent.
If container cleanup fails, leave PUBLICATION open so it can be retried."
  (unless (epub-reader-publication-closed-p publication)
    (epub-reader-container-close
     (epub-reader-publication-container publication))
    (setf (epub-reader-publication-closed-p publication) t))
  nil)

(defun epub-reader-publication-spine-resource (publication index)
  "Return PUBLICATION spine resource at zero-based INDEX."
  (let ((item (and (>= index 0)
                   (< index (length
                             (epub-reader-publication-spine publication)))
                   (aref (epub-reader-publication-spine publication) index))))
    (and item (epub-reader-spine-item-resource item))))

(defun epub-reader-publication-load-section (publication spine-index)
  "Parse and return PUBLICATION's section at zero-based SPINE-INDEX.

This is the public boundary that owns spine resource validation, temporary
container paths, XML parsing, and the XHTML `base' element."
  (when (epub-reader-publication-closed-p publication)
    (signal 'epub-reader-publication-error
            '("Cannot load a section from a closed publication")))
  (let ((resource
         (epub-reader-publication-spine-resource publication spine-index)))
    (unless resource
      (signal 'args-out-of-range
              (list spine-index
                    (length (epub-reader-publication-spine publication)))))
    (when (epub-reader-resource-remote-p resource)
      (signal 'epub-reader-publication-error
              '("Cannot parse a remote spine section")))
    (let ((file
           (epub-reader-publication--materialize-manifest-resource
            publication resource)))
      (unless (and file (file-readable-p file))
        (signal 'epub-reader-publication-error
                (list (format "Spine section is missing: %s"
                              (epub-reader-resource-path resource)))))
      (let* ((document (epub-reader-publication--parse-file file))
             (path (epub-reader-resource-path resource))
             (head
              (epub-reader-publication--descendant
               document "head" epub-reader-publication--xhtml-namespace))
             (base-node
              (and head
                   (epub-reader-publication--child
                    head "base" epub-reader-publication--xhtml-namespace)))
             (base-href
              (and base-node
                   (epub-reader-publication--attribute base-node "href")))
             (base-target
              (and base-href
                   (epub-reader-publication-resolve-href
                    publication path base-href))))
        (when (and base-target
                   (epub-reader-link-target-external-p base-target))
          (signal 'epub-reader-publication-error
                  (list (format "Remote XHTML base is unsupported: %s"
                                base-href))))
        (when (and base-target (epub-reader-link-target-fragment base-target))
          (signal 'epub-reader-publication-error
                  (list (format "XHTML base cannot contain a fragment: %s"
                                base-href))))
        (epub-reader-section--create
         :spine-index spine-index :resource resource :path path
         :base-path (if base-target
                        (epub-reader-link-target-path base-target)
                      path)
         :document document)))))

(defun epub-reader-publication-resolve-resource (publication section href)
  "Resolve and materialize HREF relative to SECTION in PUBLICATION."
  (unless (epub-reader-section-p section)
    (signal 'wrong-type-argument (list 'epub-reader-section-p section)))
  (let ((target
         (epub-reader-publication-resolve-href
          publication (epub-reader-section-base-path section) href)))
    (unless (epub-reader-link-target-external-p target)
      (setf (epub-reader-link-target-file target)
            (epub-reader-container-materialize-member
             (epub-reader-publication-container publication)
             (epub-reader-link-target-path target))))
    target))

(provide 'epub-reader-publication)
;;; epub-reader-publication.el ends here
