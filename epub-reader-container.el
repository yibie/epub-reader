;;; epub-reader-container.el --- Safe EPUB archive access -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Parse bounded ZIP central-directory metadata in Emacs, validate every OCF
;; path, then stream each member through unzip or bsdtar into a chosen file.
;; Neither adapter controls destination paths and no member is materialized in
;; an Emacs buffer before actual byte limits are enforced.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ucs-normalize)

(defgroup epub-reader nil
  "Read EPUB publications in Emacs."
  :group 'applications)

(defcustom epub-reader-container-adapters '(unzip bsdtar)
  "Archive adapters tried by `epub-reader-container-open'."
  :type '(repeat (choice (const unzip) (const bsdtar)))
  :group 'epub-reader)

(defcustom epub-reader-container-max-entries 10000
  "Maximum total number of file and directory members in one EPUB."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-files 10000
  "Maximum number of regular archive members accepted from one EPUB."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-directories 2000
  "Maximum number of explicit directory members accepted from one EPUB."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-central-directory-bytes (* 8 1024 1024)
  "Maximum bytes read from a ZIP central directory."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-path-bytes 2048
  "Maximum UTF-8 byte length of one archive member path."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-entry-bytes (* 64 1024 1024)
  "Maximum declared and actual uncompressed bytes for one member."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-total-bytes (* 512 1024 1024)
  "Maximum declared and actual uncompressed bytes for one EPUB."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-compression-ratio 1000
  "Maximum declared uncompressed-to-compressed size ratio for one member."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-member-timeout 30
  "Maximum wall-clock seconds allowed to extract one archive member."
  :type 'number
  :group 'epub-reader)

(define-error 'epub-reader-error "EPUB reader error")
(define-error 'epub-reader-container-error
  "Could not open EPUB container" 'epub-reader-error)
(define-error 'epub-reader-unsafe-archive
  "Unsafe EPUB archive" 'epub-reader-container-error)
(define-error 'epub-reader-archive-limit
  "EPUB archive exceeded a resource limit" 'epub-reader-unsafe-archive)
(define-error 'epub-reader-archive-timeout
  "EPUB archive extraction timed out" 'epub-reader-archive-limit)

(cl-defstruct (epub-reader-container
               (:constructor epub-reader-container--create))
  "A lazily materialized EPUB archive owned by the caller."
  source root adapter entry-table materialized materializing
  materialized-bytes closed-p)

(cl-defstruct (epub-reader-container-entry
               (:constructor epub-reader-container-entry--create))
  "Bounded metadata for one ZIP central-directory member."
  name compressed-size size method flags local-offset directory-p)

(defun epub-reader-container--program (adapter)
  "Return executable name for ADAPTER, or nil when unavailable."
  (pcase adapter
    ('unzip (executable-find "unzip"))
    ('bsdtar (executable-find "bsdtar"))
    (_ nil)))

(defun epub-reader-container--choose-adapter ()
  "Return the first configured, available archive adapter."
  (or (cl-find-if #'epub-reader-container--program
                  epub-reader-container-adapters)
      (signal 'epub-reader-container-error
              '("Neither unzip nor bsdtar is available"))))

(defun epub-reader-container--u16 (bytes offset)
  "Read a little-endian unsigned 16-bit value from BYTES at OFFSET."
  (logior (aref bytes offset)
          (ash (aref bytes (1+ offset)) 8)))

(defun epub-reader-container--u32 (bytes offset)
  "Read a little-endian unsigned 32-bit value from BYTES at OFFSET."
  (logior (epub-reader-container--u16 bytes offset)
          (ash (epub-reader-container--u16 bytes (+ offset 2)) 16)))

(defun epub-reader-container--signature-p (bytes offset signature)
  "Return non-nil when BYTES at OFFSET starts with four-byte SIGNATURE."
  (and (<= (+ offset 4) (length bytes))
       (cl-loop for index from 0 below 4
                always (= (aref bytes (+ offset index))
                          (aref signature index)))))

(defun epub-reader-container--read-bytes (file start length)
  "Read exactly LENGTH raw bytes from FILE beginning at START."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion))
      (insert-file-contents-literally file nil start (+ start length)))
    (unless (= (buffer-size) length)
      (signal 'epub-reader-unsafe-archive
              '("Truncated ZIP metadata")))
    (buffer-string)))

(defun epub-reader-container--eocd-position (tail)
  "Return the valid end-of-central-directory position in TAIL."
  (let ((signature (unibyte-string ?P ?K 5 6))
        found)
    (cl-loop for position downfrom (- (length tail) 22) to 0
             until found
             when (and (epub-reader-container--signature-p
                        tail position signature)
                       (= (+ position 22
                             (epub-reader-container--u16 tail (+ position 20)))
                          (length tail)))
             do (setq found position))
    (or found
        (signal 'epub-reader-unsafe-archive
                '("ZIP end-of-central-directory record was not found")))))

(defun epub-reader-container--decode-name (bytes utf8-p)
  "Decode ZIP member name BYTES, requiring valid UTF-8 when UTF8-P."
  (let* ((coding (if utf8-p 'utf-8 'cp437))
         (decoded (decode-coding-string bytes coding)))
    (when (and utf8-p
               (not (equal bytes
                           (encode-coding-string decoded 'utf-8))))
      (signal 'epub-reader-unsafe-archive
              '("ZIP member name is not valid UTF-8")))
    decoded))

(defun epub-reader-container--full-case-fold-character (character)
  "Return Unicode full case fold of CHARACTER as a string.

Emacs 29 expands most full folds through `upcase' followed by `downcase',
including sharp s and ligatures.  It lacks the two mappings below; folding
one character at a time also avoids context-sensitive final sigma output."
  (pcase character
    (#x017f "s")                 ; LATIN SMALL LETTER LONG S
    (#x1e9e "ss")                ; LATIN CAPITAL LETTER SHARP S
    (_ (downcase (upcase (char-to-string character))))))

(defun epub-reader-container--canonical-component (component)
  "Return canonical normalization plus full case-fold key for COMPONENT."
  (ucs-normalize-NFC-string
   (mapconcat #'epub-reader-container--full-case-fold-character
              (ucs-normalize-NFC-string component) "")))

(defun epub-reader-container--canonical-path (entry)
  "Return collision key for validated archive path ENTRY."
  (mapconcat #'epub-reader-container--canonical-component
             (split-string (string-remove-suffix "/" entry) "/" t) "/"))

(defun epub-reader-container--forbidden-component-p (component)
  "Return non-nil when COMPONENT contains an OCF-forbidden character."
  (or (cl-some (lambda (character)
                 (or (< character 32)
                     (and (>= character 127) (<= character 159))
                     (and (>= character #xd800) (<= character #xdfff))
                     (and (>= character #xe000) (<= character #xf8ff))
                     (and (>= character #xf0000) (<= character #xffffd))
                     (and (>= character #x100000)
                          (<= character #x10fffd))
                     (and (>= character #xfdd0) (<= character #xfdef))
                     (and (>= character #xfff0) (<= character #xffff))
                     (= (logand character #xffff) #xfffe)
                     (= (logand character #xffff) #xffff)
                     (memq character '(42 63 91 93 34 58 60 62 124))))
               (string-to-list component))
      (string-suffix-p "." component)
      (string-suffix-p " " component)))

(defun epub-reader-container--validate-entry (entry)
  "Signal `epub-reader-unsafe-archive' unless ENTRY is a safe OCF path."
  (let* ((trimmed (string-remove-suffix "/" entry))
         (components (split-string trimmed "/" nil)))
    (when (or (string-empty-p trimmed)
              (file-name-absolute-p entry)
              (string-prefix-p "~" entry)
              (string-prefix-p "-" entry)
              (string-match-p "\\`[[:alpha:]]:" entry)
              (string-match-p "[\\\\\0\r\n]" entry)
              (> (string-bytes entry) epub-reader-container-max-path-bytes)
              (cl-some (lambda (component)
                         (or (member component '("" "." ".."))
                             (> (string-bytes component) 255)
                             (epub-reader-container--forbidden-component-p
                              component)))
                       components))
      (signal 'epub-reader-unsafe-archive
              (list (format "Unsafe archive member: %S" entry)))))
  entry)

(defun epub-reader-container--check-entry-limits (entry)
  "Validate declared sizes and compression ratio of ENTRY."
  (let ((size (epub-reader-container-entry-size entry))
        (compressed (epub-reader-container-entry-compressed-size entry)))
    (when (> size epub-reader-container-max-entry-bytes)
      (signal 'epub-reader-archive-limit
              (list (format "Archive member is too large: %S"
                            (epub-reader-container-entry-name entry)))))
    (when (and (> size 0)
               (or (= compressed 0)
                   (> (/ (float size) compressed)
                      epub-reader-container-max-compression-ratio)))
      (signal 'epub-reader-archive-limit
              (list (format "Archive member compression ratio is too high: %S"
                            (epub-reader-container-entry-name entry)))))))

(defun epub-reader-container--central-directory (archive)
  "Read, bound, and validate ARCHIVE's ZIP central directory."
  (let* ((archive-size (file-attribute-size (file-attributes archive)))
         (tail-size (min archive-size 65557))
         (tail-start (- archive-size tail-size))
         (tail (epub-reader-container--read-bytes
                archive tail-start tail-size))
         (eocd (epub-reader-container--eocd-position tail))
         (disk (epub-reader-container--u16 tail (+ eocd 4)))
         (central-disk (epub-reader-container--u16 tail (+ eocd 6)))
         (disk-count (epub-reader-container--u16 tail (+ eocd 8)))
         (entry-count (epub-reader-container--u16 tail (+ eocd 10)))
         (central-size (epub-reader-container--u32 tail (+ eocd 12)))
         (central-offset (epub-reader-container--u32 tail (+ eocd 16))))
    (when (or (/= disk 0) (/= central-disk 0) (/= disk-count entry-count)
              (= entry-count #xffff) (= central-size #xffffffff)
              (= central-offset #xffffffff))
      (signal 'epub-reader-unsafe-archive
              '("Multi-disk and ZIP64 EPUB archives are unsupported")))
    (when (> entry-count epub-reader-container-max-entries)
      (signal 'epub-reader-archive-limit
              '("Archive contains too many entries")))
    (when (> central-size epub-reader-container-max-central-directory-bytes)
      (signal 'epub-reader-archive-limit
              '("ZIP central directory is too large")))
    (when (> (+ central-offset central-size) archive-size)
      (signal 'epub-reader-unsafe-archive
              '("ZIP central directory lies outside the archive")))
    (let ((central (epub-reader-container--read-bytes
                    archive central-offset central-size))
          (position 0)
          entries)
      (dotimes (_ entry-count)
        (when (or (> (+ position 46) (length central))
                  (not (epub-reader-container--signature-p
                        central position (unibyte-string ?P ?K 1 2))))
          (signal 'epub-reader-unsafe-archive
                  '("Malformed ZIP central-directory entry")))
        (let* ((flags (epub-reader-container--u16 central (+ position 8)))
               (method (epub-reader-container--u16 central (+ position 10)))
               (compressed (epub-reader-container--u32 central (+ position 20)))
               (size (epub-reader-container--u32 central (+ position 24)))
               (name-length
                (epub-reader-container--u16 central (+ position 28)))
               (extra-length
                (epub-reader-container--u16 central (+ position 30)))
               (comment-length
                (epub-reader-container--u16 central (+ position 32)))
               (local-offset
                (epub-reader-container--u32 central (+ position 42)))
               (next (+ position 46 name-length extra-length comment-length)))
          (when (or (> next (length central))
                    (= compressed #xffffffff) (= size #xffffffff)
                    (= local-offset #xffffffff)
                    (not (zerop (logand flags 1))))
            (signal 'epub-reader-unsafe-archive
                    '("Unsupported or encrypted ZIP member")))
          (let* ((raw-name (substring central (+ position 46)
                                      (+ position 46 name-length)))
                 (name (epub-reader-container--decode-name
                        raw-name (not (zerop (logand flags #x800)))))
                 (entry
                  (epub-reader-container-entry--create
                   :name name :compressed-size compressed :size size
                   :method method :flags flags :local-offset local-offset
                   :directory-p (string-suffix-p "/" name))))
            (push entry entries))
          (setq position next)))
      (unless (= position (length central))
        (signal 'epub-reader-unsafe-archive
                '("Unexpected data in ZIP central directory")))
      (nreverse entries))))

(defun epub-reader-container--check-mimetype-metadata (archive entries)
  "Require OCF-compliant first mimetype member metadata in ARCHIVE."
  (let ((first (car entries)))
    (unless (and first
                 (equal (epub-reader-container-entry-name first) "mimetype")
                 (= (epub-reader-container-entry-local-offset first) 0)
                 (= (epub-reader-container-entry-method first) 0)
                 (= (epub-reader-container-entry-size first) 20)
                 (= (epub-reader-container-entry-compressed-size first) 20))
      (signal 'epub-reader-unsafe-archive
              '("EPUB mimetype must be the first stored ZIP member")))
    (let ((local (epub-reader-container--read-bytes archive 0 38)))
      (unless (and (epub-reader-container--signature-p
                    local 0 (unibyte-string ?P ?K 3 4))
                   (= (epub-reader-container--u16 local 8) 0)
                   (= (epub-reader-container--u16 local 26) 8)
                   (= (epub-reader-container--u16 local 28) 0)
                   (equal (substring local 30 38) "mimetype"))
        (signal 'epub-reader-unsafe-archive
                '("EPUB mimetype local header has invalid metadata"))))))

(defun epub-reader-container--preflight (archive)
  "Return validated metadata entries for ARCHIVE before extraction."
  (let ((entries (epub-reader-container--central-directory archive))
        (seen (make-hash-table :test #'equal))
        (files 0)
        (directories 0)
        (declared-total 0))
    (epub-reader-container--check-mimetype-metadata archive entries)
    (dolist (entry entries)
      (let* ((name (epub-reader-container-entry-name entry))
             (canonical (progn
                          (epub-reader-container--validate-entry name)
                          (epub-reader-container--canonical-path name))))
        (when (gethash canonical seen)
          (signal 'epub-reader-unsafe-archive
                  (list (format "Archive paths collide after normalization: %S"
                                name))))
        (puthash canonical name seen)
        (if (epub-reader-container-entry-directory-p entry)
            (cl-incf directories)
          (cl-incf files)
          (epub-reader-container--check-entry-limits entry)
          (cl-incf declared-total (epub-reader-container-entry-size entry)))
        (when (> files epub-reader-container-max-files)
          (signal 'epub-reader-archive-limit
                  '("Archive contains too many files")))
        (when (> directories epub-reader-container-max-directories)
          (signal 'epub-reader-archive-limit
                  '("Archive contains too many directories")))
        (when (> declared-total epub-reader-container-max-total-bytes)
          (signal 'epub-reader-archive-limit
                  '("Archive declared size exceeds the configured limit")))))
    entries))

(defun epub-reader-container--member-command (adapter archive entry)
  "Return command list for ADAPTER to stream ENTRY from ARCHIVE."
  (let ((program (epub-reader-container--program adapter))
        (name (epub-reader-container-entry-name entry)))
    (unless program
      (signal 'epub-reader-container-error
              (list (format "Archive adapter is unavailable: %s" adapter))))
    (pcase adapter
      ('unzip (list program "-p" archive name))
      ('bsdtar (list program "-xOf" archive name)))))

(defun epub-reader-container--stream-member
    (adapter archive entry target total-counter)
  "Stream ENTRY from ARCHIVE to TARGET and update TOTAL-COUNTER.
Signal before writing a chunk that would cross an actual byte or time limit."
  (let ((entry-bytes 0)
        (failure nil)
        (stderr-text "")
        (deadline (+ (float-time) epub-reader-container-member-timeout))
        process stderr-process)
    (with-temp-file target
      (set-buffer-multibyte nil))
    (unwind-protect
        (progn
          (setq stderr-process
                (make-pipe-process
                 :name "epub-reader-stderr" :noquery t
                 :coding 'utf-8-unix
                 :filter
                 (lambda (_process chunk)
                   (let ((remaining (- 4096 (length stderr-text))))
                     (when (> remaining 0)
                       (setq stderr-text
                             (concat stderr-text
                                     (substring chunk 0
                                                (min remaining
                                                     (length chunk))))))))))
          (setq process
                (make-process
                 :name (format "epub-reader-%s" adapter)
                 :command (epub-reader-container--member-command
                           adapter archive entry)
                 :connection-type 'pipe :coding 'no-conversion
                 :noquery t :buffer nil :stderr stderr-process
                 :filter
                 (lambda (running chunk)
                   (unless failure
                     (let ((next-entry (+ entry-bytes (length chunk)))
                           (next-total (+ (car total-counter)
                                          (length chunk))))
                       (if (or (> next-entry
                                  epub-reader-container-max-entry-bytes)
                               (> next-total
                                  epub-reader-container-max-total-bytes))
                           (progn
                             (setq failure
                                   (list 'epub-reader-archive-limit
                                         "Actual extraction exceeded byte limit"))
                             (delete-process running))
                         (let ((coding-system-for-write 'no-conversion))
                           (write-region chunk nil target t 'silent))
                         (setq entry-bytes next-entry)
                         (setcar total-counter next-total)))))))
          (while (and (process-live-p process) (not failure))
            (accept-process-output process 0.05)
            (when (> (float-time) deadline)
              (setq failure
                    (list 'epub-reader-archive-timeout
                          "Archive member extraction timed out"))
              (delete-process process)))
          (accept-process-output process 0.01)
          (when failure
            (signal (car failure) (cdr failure)))
          (unless (and (eq (process-status process) 'exit)
                       (zerop (process-exit-status process)))
            (signal 'epub-reader-container-error
                    (list (format "%s failed extracting %S: %s"
                                  adapter
                                  (epub-reader-container-entry-name entry)
                                  (string-trim stderr-text)))))
          (unless (= entry-bytes (epub-reader-container-entry-size entry))
            (signal 'epub-reader-unsafe-archive
                    (list (format "Archive member size mismatch: %S"
                                  (epub-reader-container-entry-name entry)))))
          entry-bytes)
      (when (and process (process-live-p process))
        (delete-process process))
      (when (and stderr-process (process-live-p stderr-process))
        (delete-process stderr-process))
      (when (and failure (file-exists-p target))
        (delete-file target)))))

(defun epub-reader-container--target (root entry)
  "Return safe extraction path below ROOT for validated ENTRY."
  (let ((target (expand-file-name entry root)))
    (unless (file-in-directory-p target root)
      (signal 'epub-reader-unsafe-archive
              (list (format "Archive member escaped extraction root: %S"
                            entry))))
    target))

(defun epub-reader-container--verify-materialized-target (root target)
  "Require materialized TARGET's truename to remain within ROOT."
  (unless (file-in-directory-p (file-truename target) (file-truename root))
    (signal 'epub-reader-unsafe-archive
            (list (format "Extracted path escaped root: %S" target)))))

(defun epub-reader-container--extract (adapter archive root entries)
  "Stream validated ENTRIES from ARCHIVE below ROOT using ADAPTER."
  (let ((total-counter (list 0)))
    (dolist (entry entries)
      (let* ((name (epub-reader-container-entry-name entry))
             (target (epub-reader-container--target root name)))
        (if (epub-reader-container-entry-directory-p entry)
            (make-directory target t)
          (make-directory (file-name-directory target) t)
          (epub-reader-container--stream-member
           adapter archive entry target total-counter))
        (epub-reader-container--verify-materialized-target root target))))
  root)

(defun epub-reader-container--entry-table (entries)
  "Return an exact-name lookup table for validated ENTRIES."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry entries table)
      (puthash (epub-reader-container-entry-name entry) entry table))))

(defun epub-reader-container--live-entry (container relative-path)
  "Return live CONTAINER's metadata entry for RELATIVE-PATH or signal."
  (when (epub-reader-container-closed-p container)
    (signal 'epub-reader-container-error '("EPUB container is closed")))
  (epub-reader-container--validate-entry relative-path)
  (or (gethash relative-path
               (epub-reader-container-entry-table container))
      (signal 'epub-reader-container-error
              (list (format "Archive member is missing: %S"
                            relative-path)))))

;;;###autoload
(defun epub-reader-container-member-p (container relative-path)
  "Return non-nil when live CONTAINER contains RELATIVE-PATH."
  (when (epub-reader-container-closed-p container)
    (signal 'epub-reader-container-error '("EPUB container is closed")))
  (epub-reader-container--validate-entry relative-path)
  (and (gethash relative-path
                (epub-reader-container-entry-table container))
       t))

;;;###autoload
(defun epub-reader-container-member-size (container relative-path)
  "Return RELATIVE-PATH's declared uncompressed size in live CONTAINER."
  (epub-reader-container-entry-size
   (epub-reader-container--live-entry container relative-path)))

;;;###autoload
(defun epub-reader-container-materialize-member (container relative-path)
  "Materialize RELATIVE-PATH from CONTAINER once and return its local path.
The member was already path- and size-checked during central-directory
preflight.  Actual bytes are streamed into a private same-directory file and
published only after all per-member and cumulative limits pass."
  (let* ((entry (epub-reader-container--live-entry container relative-path))
         (materialized (epub-reader-container-materialized container))
         (cached (gethash relative-path materialized))
         (root (epub-reader-container-root container))
         (target (epub-reader-container--target root relative-path)))
    (cond
     ((epub-reader-container-entry-directory-p entry)
      (signal 'epub-reader-container-error
              (list (format "Cannot materialize directory member: %S"
                            relative-path))))
     (cached
      (unless (and (equal cached target) (file-regular-p cached))
        (signal 'epub-reader-container-error
                (list (format "Materialized member cache was altered: %S"
                              relative-path))))
      (epub-reader-container--verify-materialized-target root cached)
      cached)
     ((gethash relative-path
               (epub-reader-container-materializing container))
      (signal 'epub-reader-container-error
              (list (format "Recursive materialization of archive member: %S"
                            relative-path))))
     (t
      (make-directory (file-name-directory target) t)
      (let* ((temporary
              (make-temp-file
               (expand-file-name
                (concat "." (file-name-nondirectory target) ".part-")
                (file-name-directory target))))
             (total-counter
              (list (epub-reader-container-materialized-bytes container)))
             succeeded)
        (puthash relative-path t
                 (epub-reader-container-materializing container))
        (unwind-protect
            (progn
              (epub-reader-container--stream-member
               (epub-reader-container-adapter container)
               (epub-reader-container-source container)
               entry temporary total-counter)
              (epub-reader-container--verify-materialized-target
               root temporary)
              ;; A non-overwriting same-directory rename publishes only a
              ;; complete member and makes concurrent/reentrant losers fail.
              (rename-file temporary target)
              (setq temporary nil
                    succeeded t)
              (puthash relative-path target materialized)
              (setf (epub-reader-container-materialized-bytes container)
                    (car total-counter))
              target)
          (remhash relative-path
                   (epub-reader-container-materializing container))
          (unless succeeded
            (when (and temporary (file-exists-p temporary))
              (delete-file temporary)))))))))

;;;###autoload
(defun epub-reader-container-open (file)
  "Safely open EPUB FILE and return a lazy `epub-reader-container'.
The caller must eventually call `epub-reader-container-close'."
  (let ((archive (expand-file-name file)))
    (unless (file-readable-p archive)
      (signal 'file-missing (list "EPUB file is not readable" archive)))
    (let ((root (make-temp-file "epub-reader-" t))
          (adapter (epub-reader-container--choose-adapter))
          succeeded)
      (unwind-protect
          (let* ((entries (epub-reader-container--preflight archive))
                 (container
                  (epub-reader-container--create
                   :source archive :root root :adapter adapter
                   :entry-table (epub-reader-container--entry-table entries)
                   :materialized (make-hash-table :test #'equal)
                   :materializing (make-hash-table :test #'equal)
                   :materialized-bytes 0 :closed-p nil)))
            ;; These two members are the only format bootstrap required before
            ;; the publication layer can discover the OPF path.
            (epub-reader-container-materialize-member container "mimetype")
            (epub-reader-container-materialize-member
             container "META-INF/container.xml")
            (setq succeeded t)
            container)
        (unless succeeded
          (when (file-directory-p root)
            (ignore-errors (delete-directory root t))))))))

(defun epub-reader-container-path (container relative-path)
  "Return the safe target path for RELATIVE-PATH inside live CONTAINER.
This function does not materialize the member.  Use
`epub-reader-container-materialize-member' when bytes are required."
  (when (epub-reader-container-closed-p container)
    (signal 'epub-reader-container-error '("EPUB container is closed")))
  (epub-reader-container--validate-entry relative-path)
  (epub-reader-container--target
   (epub-reader-container-root container) relative-path))

(defun epub-reader-container-close (container)
  "Release extracted files owned by CONTAINER; this is idempotent.
If deletion fails, leave CONTAINER open so cleanup can be retried."
  (unless (epub-reader-container-closed-p container)
    (let ((root (epub-reader-container-root container)))
      (when (file-directory-p root)
        (delete-directory root t))
      (setf (epub-reader-container-closed-p container) t)))
  nil)

(provide 'epub-reader-container)
;;; epub-reader-container.el ends here
