;;; epub-reader-contract-test.el --- External contract tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'textui)
(require 'epub-reader-test-helper)

(defun epub-reader-contract-test--archive-entries (file)
  "Return FILE's member names using the fixture-building unzip tool."
  (with-temp-buffer
    (let ((status (process-file "unzip" nil t nil "-Z1" file)))
      (unless (zerop status)
        (error "Could not list fixture %s" file))
      (split-string (buffer-string) "\n" t))))

(defun epub-reader-contract-test--render (value width)
  "Render attributed VALUE in a TextUI leaf constrained to WIDTH."
  (let ((buffer-name (generate-new-buffer-name " *epub-textui-contract*")))
    (textui-open
     buffer-name
     (lambda (_available-width)
       `((:type :flex
          :direction :row
          :gap 0
          :children
          ((:type :text
            :value ,value
            :layout (:width ,width :min-width ,width)))))))
    (get-buffer buffer-name)))

(ert-deftest epub-reader-contract-fixtures-are-real-epub-archives ()
  (dolist (name '("epub2.epub" "epub3.epub"))
    (let* ((file (epub-reader-test-fixture name))
           (entries (epub-reader-contract-test--archive-entries file)))
      (should (file-regular-p file))
      (should (member "mimetype" entries))
      (should (member "META-INF/container.xml" entries))))
  (should
   (member "../escape.txt"
           (epub-reader-contract-test--archive-entries
            (epub-reader-test-fixture "malicious-path.epub")))))

(ert-deftest epub-reader-contract-textui-wraps-cjk-with-kinsoku ()
  (let* ((source "天地玄黄，宇宙洪荒。日月盈昃（辰宿列张），寒来暑往。")
         (buffer (epub-reader-contract-test--render source 12)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((lines (split-string
                        (buffer-substring-no-properties (point-min) (point-max))
                        "\n" t)))
            (should (> (length lines) 1))
            (dolist (line lines)
              (should-not (string-match-p "\\`[，。！？；：、）》】〕〉」』]" line))
              (should-not (string-match-p "[（《【〔〈「『]\\'" line)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest epub-reader-contract-textui-preserves-source-properties ()
  (let ((source (copy-sequence "甲乙丙丁戊己庚辛壬癸，子丑寅卯。")))
    (dotimes (index (length source))
      (put-text-property index (1+ index)
                         'epub-reader-source index source))
    (let ((buffer (epub-reader-contract-test--render source 8)))
      (unwind-protect
          (with-current-buffer buffer
            (let (seen)
              (dotimes (offset (- (point-max) (point-min)))
                (let* ((position (+ (point-min) offset))
                       (source-offset
                        (get-text-property position 'epub-reader-source)))
                  (when source-offset
                    (push source-offset seen))
                  (when (= (char-after position) #x200b)
                    (should-not source-offset))))
              (should (equal (nreverse seen)
                             (number-sequence 0 (1- (length source)))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'epub-reader-contract-test)
;;; epub-reader-contract-test.el ends here
