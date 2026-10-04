;;; run-checkdoc.el --- Run checkdoc and fail on warnings  -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage: emacs --batch -l test/run-checkdoc.el FILE...

;;; Code:

(require 'checkdoc)

(let ((count 0))
  (setq checkdoc-create-error-function
        (lambda (text start _end &optional _unfixable)
          (setq count (1+ count))
          (message "%s:%d: %s" (buffer-file-name) (line-number-at-pos start) text)
          nil))
  (dolist (file command-line-args-left)
    (with-current-buffer (find-file-noselect file)
      (checkdoc-current-buffer t)))
  (setq command-line-args-left nil)
  (kill-emacs (if (zerop count) 0 1)))

;;; run-checkdoc.el ends here
