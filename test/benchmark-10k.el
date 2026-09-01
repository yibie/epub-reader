;;; benchmark-10k.el --- EPUB 10k viewport benchmark -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'epub-reader)
(require 'epub-reader-test-helper)

(let ((epub-reader-chunk-max-blocks 32)
      (epub-reader-chunk-max-characters 4000)
      (iterations 100)
      (producer-seconds 0.0)
      (region-seconds 0.0)
      (redisplay-seconds 0.0)
      buffer)
  (setq buffer
        (epub-reader-open (epub-reader-test-fixture "long-chapter.epub")))
  (unwind-protect
      (with-current-buffer buffer
        (let* ((blocks (epub-reader-session-blocks epub-reader-ui--session))
               (limit (max 1 (- (length blocks)
                                epub-reader-chunk-max-blocks))))
          (dotimes (iteration iterations)
            (let* ((start (mod (* iteration 97) limit))
                   (end (epub-reader-ui--chunk-end blocks start))
                   (producer-start (float-time)))
              (setq textui-state
                    (epub-reader-ui--state-with-chunk
                     textui-state start end))
              (epub-reader-ui--chapter-elements epub-reader-reading-width)
              (setq producer-seconds
                    (+ producer-seconds (- (float-time) producer-start)))
              (let ((region-start (float-time)))
                (epub-reader-ui--refresh-chunk start end)
                (setq region-seconds
                      (+ region-seconds (- (float-time) region-start))))
              (let ((redisplay-start (float-time)))
                (redisplay t)
                (setq redisplay-seconds
                      (+ redisplay-seconds (- (float-time) redisplay-start))))))
          (princ
           (format
            "10k shifts=%d blocks=%d producer-ms=%.3f region-ms=%.3f redisplay-ms=%.3f\n"
            iterations (length blocks)
            (* 1000.0 (/ producer-seconds iterations))
            (* 1000.0 (/ region-seconds iterations))
            (* 1000.0 (/ redisplay-seconds iterations))))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

;;; benchmark-10k.el ends here
