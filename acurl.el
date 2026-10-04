;;; acurl.el --- Asynchronous HTTP client built on curl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Aurelien Rouene

;; Author: Aurelien Rouene <arouene@luccasoftware.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, hypermedia
;; URL: https://github.com/arouene/acurl

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; acurl runs curl as an asynchronous subprocess to fetch response
;; bodies or download files without blocking Emacs.
;;
;; Features: success and error callbacks, cancellable request handles,
;; retries with exponential backoff and jitter, Retry-After support,
;; resumable downloads, connect and total timeouts, custom headers,
;; request bodies, Content-Disposition file naming and a cap on
;; concurrent curl processes.
;;
;; Entry points: `acurl-request', `acurl-download' and `acurl-cancel'.
;; See README.md for examples.  Requires curl 7.75 or later.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'parse-time)
(require 'subr-x)
(require 'url-parse)

(defgroup acurl nil
  "Asynchronous HTTP client built on curl."
  :group 'comm
  :prefix "acurl-")

(defcustom acurl-curl-program "curl"
  "Name or path of the curl executable."
  :type 'string)

(defcustom acurl-connect-timeout 10
  "Default connection timeout in seconds, or nil for curl's default."
  :type '(choice (const :tag "Curl default" nil) number))

(defcustom acurl-timeout 300
  "Default maximum duration of one attempt in seconds, or nil for none.
A download interrupted by this timeout resumes on the next attempt."
  :type '(choice (const :tag "No limit" nil) number))

(defcustom acurl-max-redirects 10
  "Default maximum number of redirects to follow."
  :type 'natnum)

(defcustom acurl-max-attempts 3
  "Default maximum number of attempts per request, including the first."
  :type 'natnum)

(defcustom acurl-retry-base-delay 1.0
  "Backoff delay in seconds before the first retry.
The delay doubles on each retry, up to `acurl-retry-max-delay', and a
random jitter of up to half the delay is subtracted."
  :type 'number)

(defcustom acurl-retry-max-delay 30.0
  "Maximum backoff delay in seconds between two attempts."
  :type 'number)

(defcustom acurl-retry-after-max 120
  "Maximum delay in seconds honored from a Retry-After header.
Longer server requests are clamped to this value."
  :type 'number)

(defcustom acurl-retry-statuses '(408 429 500 502 503 504)
  "HTTP status codes considered transient and retried."
  :type '(repeat integer))

(defcustom acurl-retry-curl-exit-codes '(5 6 7 16 18 28 35 52 55 56 92)
  "Curl exit codes considered transient and retried.
See the EXIT CODES section of the curl manual."
  :type '(repeat integer))

(defcustom acurl-idempotent-methods '("GET" "HEAD" "PUT" "DELETE" "OPTIONS")
  "Methods retried on any transient failure.
Other methods are retried only when the request was certainly not
processed: connection failures and HTTP status 429 or 503."
  :type '(repeat string))

(defcustom acurl-http-errors t
  "Default for whether HTTP status 400 and above is reported as an error.
When nil, such responses go to the success callback.  Downloads always
report them as errors."
  :type 'boolean)

(defcustom acurl-max-concurrent 6
  "Maximum number of curl processes running at the same time."
  :type 'natnum)

(defcustom acurl-download-overwrite nil
  "Default for whether a download may replace an existing file.
When nil, a numeric suffix makes the file name unique."
  :type 'boolean)

(defcustom acurl-default-filename "download"
  "File name used when neither the response nor the URL provides one."
  :type 'string)

(defcustom acurl-extra-args nil
  "Extra arguments passed on the curl command line, for every request."
  :type '(repeat string))

(cl-defstruct (acurl-response (:constructor acurl--make-response)
                              (:copier nil))
  "Result of a request.
STATUS is the final HTTP status after redirects, URL the final URL,
HEADERS an alist of (LOWERCASE-NAME . VALUE) from the final response,
CONTENT-TYPE its Content-Type, SIZE the body size in bytes (for HEAD,
the announced Content-Length, or nil when absent), BODY the
body string for body requests, FILE the absolute path of the saved file
for downloads, REDIRECTS the number of redirects followed and ATTEMPTS
the number of attempts made."
  status url headers content-type size body file redirects attempts)

(cl-defstruct (acurl-error (:constructor acurl--make-error)
                           (:copier nil))
  "Failure of a request.
TYPE is one of `curl' (transport error), `timeout', `http' (status 400
or above) or `cancelled'.  CODE is the curl exit code for `curl' and
`timeout', the HTTP status for `http' and nil otherwise.  MESSAGE is a
human readable description.  RESPONSE is the `acurl-response' when one
was received, else nil."
  type code message response)

(cl-defstruct (acurl--req (:constructor acurl--make-req)
                          (:copier nil))
  url method headers body output directory-p on-success on-error
  connect-timeout timeout max-attempts max-redirects http-errors
  overwrite extra-args
  (attempt 1) (state 'queued) process timer
  data-file header-file body-file partial resume-from validator disposition)

(defvar acurl--queue nil
  "Requests waiting for a free process slot, in start order.")

(defvar acurl--active 0
  "Number of running curl processes.")

;;;; Parsers

(defun acurl--decode-header-value (value)
  "Decode raw header VALUE bytes as UTF-8, falling back to Latin-1."
  (let ((utf8 (decode-coding-string value 'utf-8)))
    (if (string-match-p "[\x3fff80-\x3fffff]" utf8)
        (decode-coding-string value 'latin-1)
      utf8)))

(defun acurl--parse-headers (text)
  "Parse the final response header block of TEXT, as written by curl -D.
TEXT holds one block per response (redirects, 100 Continue).  Return an
alist of (LOWERCASE-NAME . VALUE) for the last block, in order."
  (let* ((blocks (split-string text "\r?\n\r?\n" t))
         (last (car (last (cl-remove-if-not
                           (lambda (b) (string-prefix-p "HTTP/" b))
                           blocks))))
         headers)
    (when last
      ;; Values end at their last non-blank character: a lazy match or
      ;; `string-trim' before trailing blanks takes quadratic time.
      (dolist (line (cdr (split-string last "\r?\n" t)))
        (cond
         ((and headers (string-match "\\`[ \t]+\\(\\(?:.*[^ \t]\\)?\\)" line))
          (setcdr (car headers)
                  (concat (cdar headers) " " (match-string 1 line))))
         ((string-match "\\`\\([^:]+\\):[ \t]*\\(\\(?:.*[^ \t]\\)?\\)" line)
          (push (cons (downcase (match-string 1 line))
                      (acurl--decode-header-value (match-string 2 line)))
                headers)))))
    (nreverse headers)))

(defun acurl-response-header (response name)
  "Return the first value of header NAME in RESPONSE, or nil."
  (cdr (assoc (downcase name) (acurl-response-headers response))))

(defun acurl--parse-write-out (text)
  "Parse curl %{json} write-out TEXT into an alist, or nil if invalid."
  (condition-case nil
      (let ((json-object-type 'alist)
            (json-key-type 'symbol))
        (let ((data (json-read-from-string text)))
          (and (consp data) data)))
    (error nil)))

(defun acurl--parse-retry-after (value &optional now)
  "Return the delay in seconds requested by Retry-After VALUE, or nil.
VALUE is either delta-seconds or an HTTP-date.  NOW defaults to the
current time and is used for HTTP-dates."
  (when value
    (if (string-match "\\`[ \t]*\\([0-9]+\\)[ \t]*\\'" value)
        (string-to-number (match-string 1 value))
      (let ((parsed (parse-time-string value)))
        (when (and (cl-every #'integerp (cl-subseq parsed 0 6))
                   (nth 8 parsed))
          (max 0 (float-time
                  (time-subtract (encode-time parsed)
                                 (or now (current-time))))))))))

(defun acurl--unhex (string)
  "Return STRING with its %XX escapes decoded to bytes.
Unlike `url-unhex-string', this takes linear time on long values."
  (replace-regexp-in-string
   "%[0-9A-Fa-f][0-9A-Fa-f]"
   (lambda (escape) (unibyte-string (string-to-number (substring escape 1) 16)))
   string t t))

(defun acurl--decode-rfc5987 (value)
  "Decode RFC 5987 ext-value VALUE, as in filename*=UTF-8\\='\\='a%20b.
Return nil for an unsupported charset or a malformed value."
  (when (string-match "\\`\\([^']*\\)'[^']*'\\(.*\\)\\'" value)
    (let ((charset (downcase (match-string 1 value)))
          (bytes (acurl--unhex (match-string 2 value))))
      (cond ((equal charset "utf-8") (decode-coding-string bytes 'utf-8))
            ((equal charset "iso-8859-1") (decode-coding-string bytes 'latin-1))))))

(defun acurl--content-disposition-filename (value)
  "Return the file name from Content-Disposition header VALUE, or nil.
The RFC 5987 filename* parameter is preferred over filename."
  (when value
    (let ((pos 0) params)
      (while (string-match
              (concat ";[ \t]*\\([^=; \t]+\\)[ \t]*=[ \t]*"
                      "\\(\"\\(?:[^\"\\]\\|\\\\.\\)*\"\\|\\(?:[^;]*[^; \t]\\)?\\)")
              value pos)
        (setq pos (match-end 0))
        (let ((name (downcase (match-string 1 value)))
              (raw (match-string 2 value)))
          (push (cons name
                      (if (string-prefix-p "\"" raw)
                          (replace-regexp-in-string
                           "\\\\\\(.\\)" "\\1" (substring raw 1 -1) t)
                        raw))
                params)))
      (or (let ((ext (cdr (assoc "filename*" params))))
            (and ext (acurl--decode-rfc5987 ext)))
          (cdr (assoc "filename" params))))))

(defun acurl--sanitize-filename (name)
  "Return NAME reduced to a safe base file name, or nil if nothing is left.
Directories are dropped, control and reserved characters replaced, and
leading dots and tildes removed so the result is never hidden, `.', `..'
or expanded as a home directory."
  (when name
    (let* ((base (or (car (last (split-string name "[/\\]" t))) ""))
           ;; The result fits in 255 bytes: bound the work on long names.
           (base (substring base 0 (min (length base) 255)))
           (clean (replace-regexp-in-string
                   "[[:cntrl:]<>:\"|?*]" "_" base t t))
           (clean (string-trim clean "[ .~]+" "[ .]+")))
      (while (> (string-bytes clean) 255)
        (setq clean (substring clean 0 -1)))
      (unless (string-empty-p clean) clean))))

(defun acurl--url-filename (url)
  "Return the decoded last path segment of URL, or nil."
  (when url
    (let* ((path (car (url-path-and-query (url-generic-parse-url url))))
           (segment (and path (car (last (split-string path "/" t))))))
      (when segment
        (decode-coding-string (acurl--unhex segment) 'utf-8)))))

(defun acurl--decode-body (bytes content-type)
  "Decode response BYTES according to CONTENT-TYPE.
Use the charset parameter when known, UTF-8 for textual types without
one, and return BYTES unchanged otherwise."
  (let* ((ct (downcase (or content-type "")))
         (charset (and (string-match "charset=\"?\\([^\";[:space:]]+\\)" ct)
                       (intern (match-string 1 ct))))
         (coding (cond ((and charset (coding-system-p charset)) charset)
                       ((string-match-p
                         (concat "\\`\\(?:text/\\|application/"
                                 "\\(?:json\\|xml\\|javascript\\|[^;]*+\\(?:json\\|xml\\)\\)\\)")
                         ct)
                        'utf-8))))
    (if coding (decode-coding-string bytes coding) bytes)))

;;;; Process management

(defconst acurl--token-regexp "\\`[!#$%&'*+.^_`|~0-9A-Za-z-]+\\'"
  "Regexp matching an HTTP token, the syntax of methods and header names.")

(defun acurl--check-header (name value)
  "Return the curl header line for header NAME and VALUE.
Signal an error if NAME is not a token or VALUE contains a line break."
  (let ((name (format "%s" name))
        (value (format "%s" value)))
    (unless (string-match-p acurl--token-regexp name)
      (error "Invalid header name: %S" name))
    (when (string-match-p "[\r\n\0]" value)
      (error "Invalid header value for %s" name))
    (if (string-empty-p value)
        (concat name ";")
      (concat name ": " value))))

(defun acurl--config-quote (string)
  "Return STRING as a double-quoted curl config value.
Signal an error if STRING contains a line break or a null byte, which
would end the config line."
  (when (string-match-p "[\r\n\0]" string)
    (error "Line break or null byte in curl config value"))
  (concat "\"" (replace-regexp-in-string "[\\\"]" "\\\\\\&" string) "\""))

(defun acurl--build-config (req)
  "Return the curl config for REQ, holding its URL and headers.
curl reads it from stdin, so these secrets stay out of its command line,
which any local user can read."
  (encode-coding-string
   (mapconcat
    (lambda (line) (concat line "\n"))
    (cons (concat "url = " (acurl--config-quote (acurl--req-url req)))
          (mapcar (lambda (h)
                    (concat "header = "
                            (acurl--config-quote
                             (acurl--check-header (car h) (cdr h)))))
                  (append (acurl--req-headers req)
                          (when-let ((v (acurl--req-validator req)))
                            (when (> (acurl--req-resume-from req) 0)
                              (list (cons "If-Range" v)))))))
    "")
   'utf-8))

(defun acurl--build-args (req)
  "Return the curl argument list for REQ.
The URL and headers are passed on stdin, see `acurl--build-config'."
  (let ((method (acurl--req-method req)))
    (append
     ;; -q must come first: it disables ~/.curlrc.
     (list "-q" "--silent" "--globoff"
           "--proto" "=http,https" "--proto-redir" "=http,https"
           "--location" "--max-redirs"
           (number-to-string (acurl--req-max-redirects req))
           "--dump-header" (acurl--req-header-file req)
           "--write-out" "%{json}")
     (when-let ((ct (acurl--req-connect-timeout req)))
       (list "--connect-timeout" (number-to-string ct)))
     (when-let ((tt (acurl--req-timeout req)))
       (list "--max-time" (number-to-string tt)))
     (if (acurl--req-partial req)
         ;; --fail keeps error bodies out of the partial file.
         (list "--fail" "--continue-at" "-" "--output" (acurl--req-partial req))
       (list "--output" (acurl--req-body-file req)))
     (cond ((equal method "HEAD") (list "--head"))
           ((acurl--req-data-file req)
            (append (list "--data-binary" (concat "@" (acurl--req-data-file req)))
                    (unless (equal method "POST") (list "--request" method))))
           ((not (equal method "GET")) (list "--request" method)))
     acurl-extra-args
     (acurl--req-extra-args req)
     (list "--config" "-"))))

(defun acurl--pump ()
  "Start queued requests while process slots are free."
  (while (and acurl--queue (< acurl--active acurl-max-concurrent))
    (acurl--start (pop acurl--queue))))

(defun acurl--start (req)
  "Start one attempt of REQ in a new curl process."
  (setf (acurl--req-state req) 'running)
  (cl-incf acurl--active)
  (acurl--truncate (acurl--req-header-file req))
  (when-let ((partial (acurl--req-partial req)))
    (setf (acurl--req-resume-from req) (acurl--file-size partial)))
  (let ((buffer (generate-new-buffer " *acurl*"))
        (stderr (generate-new-buffer " *acurl-stderr*")))
    (condition-case err
        (let* ((config (acurl--build-config req))
               (proc (make-process
                      :name "acurl"
                      :buffer buffer
                      :stderr stderr
                      :command (cons acurl-curl-program (acurl--build-args req))
                      :coding 'binary
                      :connection-type 'pipe
                      :noquery t
                      :sentinel #'acurl--sentinel)))
          (process-put proc 'acurl-request req)
          (process-put proc 'acurl-stderr stderr)
          (setf (acurl--req-process req) proc)
          ;; If curl exits before reading, the sentinel reports its status.
          (ignore-errors
            (process-send-string proc config)
            (process-send-eof proc)))
      (error
       (kill-buffer buffer)
       (kill-buffer stderr)
       (cl-decf acurl--active)
       (acurl--finish req (acurl--make-error
                           :type 'curl
                           :message (error-message-string err)))))))

(defun acurl--release (proc)
  "Kill the buffers of PROC and free its process slot."
  (let ((stderr (process-get proc 'acurl-stderr)))
    (when (buffer-live-p stderr) (kill-buffer stderr)))
  (when (buffer-live-p (process-buffer proc))
    (kill-buffer (process-buffer proc)))
  (cl-decf acurl--active))

(defun acurl--read-file (file)
  "Return the contents of FILE as a unibyte string, or nil if unreadable."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-string))))

(defun acurl--sentinel (proc _event)
  "Handle the exit of curl process PROC."
  (unless (process-live-p proc)
    (let* ((req (process-get proc 'acurl-request))
           (out (with-current-buffer (process-buffer proc) (buffer-string)))
           (exit (process-exit-status proc)))
      (acurl--release proc)
      (setf (acurl--req-process req) nil)
      (when (eq (acurl--req-state req) 'running)
        (acurl--handle-exit
         req exit
         (acurl--parse-write-out (decode-coding-string out 'utf-8))
         (acurl--parse-headers
          (or (acurl--read-file (acurl--req-header-file req)) "")))))))

(defun acurl--handle-exit (req exit write-out headers)
  "Process the outcome of an attempt of REQ.
EXIT is the curl exit code, WRITE-OUT the parsed metadata and HEADERS
the final response headers."
  (let* ((status (or (alist-get 'http_code write-out) 0))
         (partial (acurl--req-partial req))
         (resp (acurl--make-response
                :status status
                :url (or (alist-get 'url_effective write-out)
                         (acurl--req-url req))
                :headers headers
                :content-type (alist-get 'content_type write-out)
                :redirects (alist-get 'num_redirects write-out)
                :attempts (acurl--req-attempt req)))
         (err (cond
               ((and (= exit 0) (< status 400)) nil)
               ((= exit 28)
                (acurl--make-error :type 'timeout :code exit :response resp
                                   :message (or (alist-get 'errormsg write-out)
                                                "Timeout")))
               ((or (= exit 22) (and (= exit 0) (>= status 400)))
                (acurl--make-error :type 'http :code status :response resp
                                   :message (format "HTTP status %d" status)))
               (t
                (acurl--make-error :type 'curl :code exit :response resp
                                   :message (or (alist-get 'errormsg write-out)
                                                (format "curl exited with code %d"
                                                        exit)))))))
    (when-let ((cd (cdr (assoc "content-disposition" headers))))
      (setf (acurl--req-disposition req) cd))
    (when (and partial (= (acurl--req-resume-from req) 0))
      (setf (acurl--req-validator req)
            (let ((etag (cdr (assoc "etag" headers))))
              (if (and etag (not (string-prefix-p "W/" etag)))
                  etag
                (cdr (assoc "last-modified" headers))))))
    (cond
     ((and (not partial) (equal (acurl--req-method req) "HEAD"))
      (let ((len (cdr (assoc "content-length" headers))))
        (setf (acurl-response-body resp) ""
              (acurl-response-size resp)
              (and len (string-match-p "\\`[0-9]+\\'" len)
                   (string-to-number len)))))
     ((not partial)
      (let ((bytes (or (acurl--read-file (acurl--req-body-file req)) "")))
        (setf (acurl-response-size resp) (length bytes)
              (acurl-response-body resp)
              (acurl--decode-body bytes (acurl-response-content-type resp))))))
    (cond
     ;; Partial file rejected: the server ignored the range or the
     ;; resource changed (33), or it cannot satisfy the range (416).
     ;; Restart from scratch, no attempt used.
     ((and partial (> (acurl--req-resume-from req) 0)
           (or (= exit 33) (= status 416)))
      (acurl--truncate partial)
      (acurl--enqueue req t))
     ((and err (acurl--retry-p req err))
      ;; --fail keeps error bodies out of the partial file, except for
      ;; some 401/407 responses: drop the file if one slipped through.
      (when (and partial (eq (acurl-error-type err) 'http)
                 (/= (acurl--file-size partial) (acurl--req-resume-from req)))
        (acurl--truncate partial))
      (acurl--schedule-retry req (acurl--retry-delay req resp)))
     ((and err (or partial
                   (not (eq (acurl-error-type err) 'http))
                   (acurl--req-http-errors req)))
      (acurl--finish req err))
     ((not partial) (acurl--finish req nil resp))
     (t
      (let ((file (condition-case e
                      (acurl--install-download req resp)
                    (error (acurl--finish req (acurl--make-error
                                               :type 'curl :response resp
                                               :message (error-message-string e)))
                           nil))))
        (when file
          (setf (acurl--req-partial req) nil
                (acurl-response-file resp) file
                (acurl-response-size resp) (acurl--file-size file))
          (acurl--finish req nil resp)))))))

(defun acurl--file-size (file)
  "Return the size of FILE in bytes, or 0 if it does not exist."
  (or (file-attribute-size (file-attributes file)) 0))

(defun acurl--truncate (file)
  "Empty FILE."
  (let ((coding-system-for-write 'binary))
    (write-region "" nil file nil 'silent)))

(defun acurl--retry-p (req err)
  "Return non-nil if REQ may be retried after ERR."
  (let ((type (acurl-error-type err))
        (code (acurl-error-code err))
        (idempotent (member (acurl--req-method req) acurl-idempotent-methods)))
    (and (< (acurl--req-attempt req) (acurl--req-max-attempts req))
         (pcase type
           ('http (and (memq code acurl-retry-statuses)
                       (or idempotent (memq code '(429 503)))))
           ((or 'curl 'timeout)
            (and (memq code acurl-retry-curl-exit-codes)
                 (or idempotent (memq code '(6 7)))))))))

(defun acurl--retry-delay (req resp)
  "Return the delay in seconds before the next attempt of REQ.
Use the Retry-After header of RESP when present, else exponential
backoff with jitter."
  (let ((after (acurl--parse-retry-after
                (acurl-response-header resp "retry-after"))))
    (if after
        (min after acurl-retry-after-max)
      (let ((delay (min acurl-retry-max-delay
                        (* acurl-retry-base-delay
                           (expt 2 (1- (acurl--req-attempt req)))))))
        (- delay (* delay 0.5 (/ (random 1000) 1000.0)))))))

(defun acurl--schedule-retry (req delay)
  "Start the next attempt of REQ after DELAY seconds."
  (cl-incf (acurl--req-attempt req))
  (setf (acurl--req-state req) 'waiting)
  (setf (acurl--req-timer req)
        (run-at-time delay nil
                     (lambda ()
                       (setf (acurl--req-timer req) nil)
                       (acurl--enqueue req t))))
  (acurl--pump))

(defun acurl--enqueue (req &optional front)
  "Queue REQ, at the FRONT of the queue if non-nil, and pump the queue."
  (setf (acurl--req-state req) 'queued)
  (setq acurl--queue (if front
                         (cons req acurl--queue)
                       (append acurl--queue (list req))))
  (acurl--pump))

(defun acurl--install-download (req resp)
  "Rename the partial file of REQ to its final name and return that name.
RESP is the final response, used to name files in directory mode."
  (let* ((output (acurl--req-output req))
         (target (if (acurl--req-directory-p req)
                     (expand-file-name
                      (or (acurl--sanitize-filename
                           (acurl--content-disposition-filename
                            (acurl--req-disposition req)))
                          (acurl--sanitize-filename
                           (acurl--url-filename (acurl-response-url resp)))
                          (acurl--sanitize-filename
                           (acurl--url-filename (acurl--req-url req)))
                          acurl-default-filename)
                      output)
                   output)))
    (if (acurl--req-overwrite req)
        (progn (rename-file (acurl--req-partial req) target t) target)
      (let ((n 0) (candidate target) done)
        (while (not done)
          (condition-case nil
              (progn (rename-file (acurl--req-partial req) candidate)
                     (setq done t))
            (file-already-exists
             (setq n (1+ n)
                   candidate (concat (file-name-sans-extension target)
                                     "-" (number-to-string n)
                                     (if-let ((ext (file-name-extension target)))
                                         (concat "." ext)
                                       ""))))))
        candidate))))

(defun acurl--delete-files (req)
  "Delete the temporary files of REQ."
  (dolist (file (list (acurl--req-data-file req) (acurl--req-header-file req)
                      (acurl--req-body-file req) (acurl--req-partial req)))
    (when (and file (file-exists-p file))
      (delete-file file))))

(defun acurl--finish (req err &optional resp)
  "Mark REQ as done, clean up and call its callback with ERR or RESP."
  (setf (acurl--req-state req) 'done)
  (acurl--delete-files req)
  (acurl--pump)
  (if err
      (funcall (acurl--req-on-error req) err)
    (funcall (acurl--req-on-success req) resp)))

;;;; Public API

;;;###autoload
(cl-defun acurl-request (url &key (method "GET") headers body output
                             on-success on-error
                             (connect-timeout acurl-connect-timeout)
                             (timeout acurl-timeout)
                             (max-attempts acurl-max-attempts)
                             (max-redirects acurl-max-redirects)
                             (http-errors acurl-http-errors)
                             (overwrite acurl-download-overwrite)
                             extra-args)
  "Start an asynchronous HTTP request to URL and return its handle.
The handle can be passed to `acurl-cancel'.

METHOD is the HTTP method, a string such as \"GET\" (default), \"HEAD\",
\"POST\", \"PUT\", \"PATCH\" or \"DELETE\".  HEADERS is an alist of
\(NAME . VALUE).  BODY is the request body string, encoded as UTF-8 when
multibyte; POST, PUT and PATCH send an empty body when it is nil.

OUTPUT, when non-nil, turns the request into a download: a directory
\(an existing directory or a name ending in a slash) where the file is
named after the Content-Disposition header, the URL or
`acurl-default-filename', or a file name.  An existing file is kept and
a numeric suffix added unless OVERWRITE is non-nil.

ON-SUCCESS is called with an `acurl-response'.  ON-ERROR is called with
an `acurl-error'; it defaults to displaying the error message.

CONNECT-TIMEOUT and TIMEOUT are in seconds.  MAX-ATTEMPTS bounds the
number of attempts, MAX-REDIRECTS the redirects followed.  HTTP-ERRORS
controls whether status 400 and above is an error for body requests.
EXTRA-ARGS is a list of strings passed on the curl command line.

Defaults come from the `acurl' customization group."
  (unless (string-match-p "\\`https?://[^\r\n\0]*\\'" url)
    (error "Unsupported URL: %S" url))
  (unless (executable-find acurl-curl-program)
    (error "Curl executable not found: %s" acurl-curl-program))
  (dolist (h headers) (acurl--check-header (car h) (cdr h)))
  (unless (string-match-p acurl--token-regexp method)
    (error "Invalid method: %S" method))
  (let* ((method (upcase method))
         (body (or body (and (member method '("POST" "PUT" "PATCH")) "")))
         (directory-p (and output (or (directory-name-p output)
                                      (file-directory-p output))))
         (output (and output (if directory-p
                                 (file-name-as-directory (expand-file-name output))
                               (expand-file-name output))))
         (target-dir (and output (file-name-directory output))))
    (when (and target-dir (not (file-directory-p target-dir)))
      (error "Download directory does not exist: %s" target-dir))
    (let ((req (acurl--make-req
                :url url :method method :headers headers :output output
                :directory-p directory-p
                :on-success (or on-success #'ignore)
                :on-error (or on-error
                              (lambda (err)
                                (message "acurl: %s: %s" url
                                         (acurl-error-message err))))
                :connect-timeout connect-timeout :timeout timeout
                :max-attempts (max 1 max-attempts)
                :max-redirects max-redirects
                :http-errors http-errors :overwrite overwrite
                :extra-args extra-args
                :header-file (make-temp-file "acurl-headers-"))))
      (condition-case err
          (progn
            (when body
              (let ((file (make-temp-file "acurl-data-"))
                    (coding-system-for-write 'binary))
                (setf (acurl--req-data-file req) file)
                (write-region (if (multibyte-string-p body)
                                  (encode-coding-string body 'utf-8)
                                body)
                              nil file nil 'silent)))
            (if output
                (setf (acurl--req-partial req)
                      (make-temp-file (expand-file-name ".acurl-" target-dir)
                                      nil ".part"))
              (setf (acurl--req-body-file req) (make-temp-file "acurl-body-"))))
        ;; The data file holds the body, which may be secret.
        (t (acurl--delete-files req)
           (signal (car err) (cdr err))))
      (acurl--enqueue req)
      req)))

;;;###autoload
(defun acurl-download (url output &rest args)
  "Download URL to OUTPUT asynchronously and return the request handle.
OUTPUT is a directory or a file name, see `acurl-request'.  ARGS are
keyword arguments accepted by `acurl-request'.  The `acurl-response'
passed to the success callback holds the absolute path in its FILE slot."
  (apply #'acurl-request url :output output args))

(defun acurl-cancel (handle)
  "Cancel the request HANDLE returned by `acurl-request'.
Its error callback receives an error of type `cancelled'.  Do nothing if
the request already completed."
  (unless (eq (acurl--req-state handle) 'done)
    (pcase (acurl--req-state handle)
      ('queued (setq acurl--queue (delq handle acurl--queue)))
      ('waiting (cancel-timer (acurl--req-timer handle)))
      ('running
       (let ((proc (acurl--req-process handle)))
         (set-process-sentinel proc #'ignore)
         (delete-process proc)
         (acurl--release proc))))
    (acurl--finish handle (acurl--make-error :type 'cancelled
                                             :message "Request cancelled"))))

(provide 'acurl)
;;; acurl.el ends here
