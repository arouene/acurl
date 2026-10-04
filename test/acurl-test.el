;;; acurl-test.el --- Tests for acurl  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the parsers and integration tests against
;; test/server.py, started on demand on an ephemeral port.

;;; Code:

(require 'acurl)
(require 'ert)
(require 'json)
(require 'url-util)

(defconst acurl-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

;;;; Parsers

(ert-deftest acurl-test-parse-headers-last-block ()
  (let ((h (acurl--parse-headers
            (concat "HTTP/1.1 302 Found\r\nLocation: /a\r\nX-A: 1\r\n\r\n"
                    "HTTP/1.1 100 Continue\r\n\r\n"
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                    "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n"
                    "X-Long: one\r\n two\r\n\r\n"))))
    (should (equal h '(("content-type" . "text/plain")
                       ("set-cookie" . "a=1")
                       ("set-cookie" . "b=2")
                       ("x-long" . "one two"))))))

(ert-deftest acurl-test-parse-headers-encoding ()
  (should (equal (acurl--parse-headers
                  (encode-coding-string "HTTP/1.1 200 OK\r\nX: été\r\n\r\n" 'utf-8))
                 '(("x" . "été"))))
  (should (equal (acurl--parse-headers
                  (encode-coding-string "HTTP/1.1 200 OK\r\nX: été\r\n\r\n" 'latin-1))
                 '(("x" . "été"))))
  (should-not (acurl--parse-headers "")))

(ert-deftest acurl-test-parse-write-out ()
  (let ((wo (acurl--parse-write-out
             "{\"http_code\":200,\"url_effective\":\"http://x/é\",\"content_type\":null}")))
    (should (equal (alist-get 'http_code wo) 200))
    (should (equal (alist-get 'url_effective wo) "http://x/é"))
    (should-not (alist-get 'content_type wo)))
  (should-not (acurl--parse-write-out ""))
  (should-not (acurl--parse-write-out "garbage{"))
  (should-not (acurl--parse-write-out "42")))

(ert-deftest acurl-test-parse-retry-after ()
  (should (equal (acurl--parse-retry-after "120") 120))
  (should (equal (acurl--parse-retry-after " 5 ") 5))
  (let ((now (encode-time '(0 28 7 21 10 2015 nil nil 0))))
    (should (= (acurl--parse-retry-after "Wed, 21 Oct 2015 07:28:30 GMT" now) 30))
    (should (= (acurl--parse-retry-after "Wed, 21 Oct 2015 07:00:00 GMT" now) 0)))
  (should-not (acurl--parse-retry-after nil))
  (should-not (acurl--parse-retry-after "soon"))
  (should-not (acurl--parse-retry-after "-5")))

(ert-deftest acurl-test-content-disposition ()
  (should (equal (acurl--content-disposition-filename
                  "attachment; filename=\"a b.txt\"")
                 "a b.txt"))
  (should (equal (acurl--content-disposition-filename
                  "attachment; filename=plain.txt")
                 "plain.txt"))
  (should (equal (acurl--content-disposition-filename
                  "attachment; filename=\"q\\\"uote;d.txt\"; size=3")
                 "q\"uote;d.txt"))
  (should (equal (acurl--content-disposition-filename
                  "attachment; filename=\"fallback.txt\"; filename*=UTF-8''%C3%A9t%C3%A9.txt")
                 "été.txt"))
  (should (equal (acurl--content-disposition-filename
                  "attachment; FILENAME*=iso-8859-1'en'%E9t%E9.txt")
                 "été.txt"))
  (should (equal (acurl--content-disposition-filename
                  "attachment; filename*=bogus''x.txt; filename=y.txt")
                 "y.txt"))
  (should-not (acurl--content-disposition-filename "inline"))
  (should-not (acurl--content-disposition-filename nil)))

(ert-deftest acurl-test-sanitize-filename ()
  (should (equal (acurl--sanitize-filename "report.pdf") "report.pdf"))
  (should (equal (acurl--sanitize-filename "../../etc/passwd") "passwd"))
  (should (equal (acurl--sanitize-filename "/abs/path.txt") "path.txt"))
  (should (equal (acurl--sanitize-filename "C:\\Windows\\evil.exe") "evil.exe"))
  (should (equal (acurl--sanitize-filename ".bashrc") "bashrc"))
  (should (equal (acurl--sanitize-filename "~root") "root"))
  (should (equal (acurl--sanitize-filename ".~/x~") "x~"))
  (should-not (acurl--sanitize-filename "~"))
  (should (equal (acurl--sanitize-filename "a\nb<c>.txt") "a_b_c_.txt"))
  (should (equal (acurl--sanitize-filename "été.txt") "été.txt"))
  (should-not (acurl--sanitize-filename ".."))
  (should-not (acurl--sanitize-filename "../"))
  (should-not (acurl--sanitize-filename ""))
  (should-not (acurl--sanitize-filename nil))
  (should (<= (string-bytes (acurl--sanitize-filename (make-string 300 ?é))) 255))
  ;; DEL, C1 controls, bidi overrides, zero width and line separators.
  (should (equal (acurl--sanitize-filename "a\177b\u0085c\u202Ed\u200Be\u2028f.txt")
                 "a_b_c_d_e_f.txt"))
  (should (equal (acurl--sanitize-filename "con.txt") "con.txt"))
  (let ((system-type 'windows-nt))
    (should (equal (acurl--sanitize-filename "con.txt") "_con.txt"))
    (should (equal (acurl--sanitize-filename "NUL") "_NUL"))
    (should (equal (acurl--sanitize-filename "Com1.tar.gz") "_Com1.tar.gz"))
    (should (equal (acurl--sanitize-filename "console.txt") "console.txt"))))

(ert-deftest acurl-test-url-filename ()
  (should (equal (acurl--url-filename "http://h/a/b/file%20name.tar.gz?x=1#f")
                 "file name.tar.gz"))
  (should (equal (acurl--url-filename "http://h/d/%C3%A9t%C3%A9") "été"))
  (should-not (acurl--url-filename "http://h/"))
  (should-not (acurl--url-filename "http://h")))

(ert-deftest acurl-test-decode-body ()
  (let ((bytes (encode-coding-string "é" 'utf-8)))
    (should (equal (acurl--decode-body bytes "text/plain") "é"))
    (should (equal (acurl--decode-body bytes "application/json") "é"))
    (should (equal (acurl--decode-body bytes "application/vnd.api+json") "é"))
    (should (equal (acurl--decode-body bytes "application/octet-stream") bytes))
    (should (equal (acurl--decode-body bytes nil) bytes)))
  (should (equal (acurl--decode-body "\351" "text/plain; charset=ISO-8859-1") "é"))
  ;; A server must not grow the obarray with names of its choice.
  (should (equal (acurl--decode-body "x" "text/plain; charset=acurl-test-no-such-charset") "x"))
  (should-not (intern-soft "acurl-test-no-such-charset")))

(ert-deftest acurl-test-hostile-values-linear-time ()
  ;; Server values reach curl's 100 KB header limit: quadratic parsing
  ;; froze Emacs for minutes.
  (let ((spaces (make-string 100000 ?\s))
        (escapes (apply #'concat (make-list 33000 "%41")))
        (start (float-time)))
    (should (equal (acurl--parse-headers
                    (concat "HTTP/1.1 200 OK\r\nX: a" spaces "b" spaces "\r\n"
                            "Y: a\r\n " spaces "c" spaces "\r\n\r\n"))
                   `(("x" . ,(concat "a" spaces "b")) ("y" . "a c"))))
    (should (equal (acurl--content-disposition-filename
                    (concat "attachment; filename=a" spaces "b" spaces "; x=1"))
                   (concat "a" spaces "b")))
    (should (= (length (acurl--content-disposition-filename
                        (concat "attachment; filename*=UTF-8''" escapes))) 33000))
    (should (= (length (acurl--url-filename (concat "http://h/" escapes))) 33000))
    (should (equal (acurl--sanitize-filename (concat (make-string 100000 ?a) spaces))
                   (make-string 255 ?a)))
    (should (< (- (float-time) start) 2))))

(ert-deftest acurl-test-check-header ()
  (should (equal (acurl--check-header "X-A" "1") "X-A: 1"))
  (should (equal (acurl--check-header 'X-B 2) "X-B: 2"))
  (should (equal (acurl--check-header "X-Empty" "") "X-Empty;"))
  (should-error (acurl--check-header "X-A" "1\r\nInjected: yes"))
  (should-error (acurl--check-header "@file" "x"))
  (should-error (acurl--check-header "Bad Name" "x")))

(ert-deftest acurl-test-config-quote ()
  (should (equal (acurl--config-quote "a b") "\"a b\""))
  (should (equal (acurl--config-quote "a\"b\\c") "\"a\\\"b\\\\c\""))
  (should-error (acurl--config-quote "a\n-o /tmp/x"))
  (should-error (acurl--config-quote "a\rb"))
  (should-error (acurl--config-quote "a\0b")))

(ert-deftest acurl-test-request-validation ()
  (should-error (acurl-request "file:///etc/passwd"))
  (should-error (acurl-request "-o/tmp/x http://h/"))
  (should-error (acurl-request "http://h/\noutput = /tmp/x"))
  (should-error (acurl-request "http://h/" :headers '(("X" . "a\nb"))))
  (should-error (acurl-request "http://h/" :method "GET / HTTP/1.1\r\nX-Injected: 1\r\nX:"))
  (should-error (acurl-request "http://h/" :method "GET /other"))
  (should-error (acurl-download "http://h/" "/nonexistent-acurl-dir/x")))

(ert-deftest acurl-test-request-error-cleans-temp-files ()
  (let* ((dir (file-name-as-directory (make-temp-file "acurl-test-" t)))
         (temporary-file-directory dir)
         (make-temp-file-orig (symbol-function 'make-temp-file)))
    (unwind-protect
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (prefix &rest args)
                     (if (string-match-p "\\.acurl-" prefix)
                         (error "Disk full")
                       (apply make-temp-file-orig prefix args)))))
          (should-error (acurl-download "http://127.0.0.1:1/" dir :body "secret"))
          (should-not (directory-files dir nil "\\`[^.]")))
      (delete-directory dir t))))

;;;; Integration

(defvar acurl-test--server nil)
(defvar acurl-test--port nil)

(defun acurl-test--ensure-server ()
  "Start test/server.py once and record its port."
  (unless (process-live-p acurl-test--server)
    (setq acurl-test--port nil)
    (setq acurl-test--server
          (make-process
           :name "acurl-test-server"
           :buffer (generate-new-buffer " *acurl-test-server*")
           :command (list "python3" (expand-file-name "server.py" acurl-test--dir))
           :noquery t
           :connection-type 'pipe))
    (with-timeout (10 (error "Test server did not start"))
      (while (not acurl-test--port)
        (accept-process-output acurl-test--server 0.1)
        (with-current-buffer (process-buffer acurl-test--server)
          (when (string-match "\\([0-9]+\\)\n" (buffer-string))
            (setq acurl-test--port (match-string 1 (buffer-string)))))))))

(defun acurl-test--url (path)
  "Return the test server URL for PATH."
  (acurl-test--ensure-server)
  (format "http://127.0.0.1:%s%s" acurl-test--port path))

(defun acurl-test--key ()
  "Return a unique key for stateful server endpoints."
  (format "k%d%d" (random 1000000) (float-time)))

(defun acurl-test--wait (handle-fn)
  "Call HANDLE-FN with callbacks and wait for its outcome.
HANDLE-FN receives a success and an error callback.  Return
\(success . RESPONSE) or (error . ERROR)."
  (let (result)
    (funcall handle-fn
             (lambda (r) (setq result (cons 'success r)))
             (lambda (e) (setq result (cons 'error e))))
    (with-timeout (30 (error "Request did not complete"))
      (while (not result)
        (accept-process-output nil 0.05)))
    result))

(defun acurl-test--run (url &rest args)
  "Run a request to URL with ARGS and return the outcome."
  (acurl-test--wait
   (lambda (ok ko)
     (apply #'acurl-request url :on-success ok :on-error ko args))))

(defun acurl-test--get-json (path)
  "Return the parsed JSON body of PATH on the test server."
  (let ((json-object-type 'alist) (json-array-type 'list))
    (json-read-from-string
     (acurl-response-body (cdr (acurl-test--run (acurl-test--url path)))))))

(defun acurl-test--payload ()
  "Return the binary payload served by the test server."
  (let ((s (make-string 102400 0)))
    (dotimes (i 102400) (aset s i (% i 256)))
    (string-to-unibyte s)))

(defmacro acurl-test--with-dir (var &rest body)
  "Bind VAR to a fresh temporary directory around BODY."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "acurl-test-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defmacro acurl-test--fast-retries (&rest body)
  "Run BODY with short retry delays."
  `(let ((acurl-retry-base-delay 0.05)
         (acurl-retry-max-delay 0.1))
     ,@body))

(ert-deftest acurl-test-get-text ()
  (let* ((out (acurl-test--run (acurl-test--url "/text")))
         (r (cdr out)))
    (should (eq (car out) 'success))
    (should (= (acurl-response-status r) 200))
    (should (equal (acurl-response-body r) "héllo wörld"))
    (should (= (acurl-response-size r) 13))
    (should (equal (acurl-response-content-type r) "text/plain; charset=utf-8"))
    (should (equal (acurl-response-header r "Content-Type") "text/plain; charset=utf-8"))
    (should (= (acurl-response-redirects r) 0))
    (should (= (acurl-response-attempts r) 1))
    (should-not (acurl-response-file r))))

(ert-deftest acurl-test-charset-and-binary ()
  (should (equal (acurl-response-body (cdr (acurl-test--run (acurl-test--url "/latin1"))))
                 "héllo"))
  (let ((r (cdr (acurl-test--run (acurl-test--url "/binary")))))
    (should (= (acurl-response-size r) 102400))
    (should-not (multibyte-string-p (acurl-response-body r)))
    (should (= (aref (acurl-response-body r) 255) 255))))

(ert-deftest acurl-test-redirects ()
  (let ((r (cdr (acurl-test--run (acurl-test--url "/redirect/3")))))
    (should (= (acurl-response-status r) 200))
    (should (= (acurl-response-redirects r) 3))
    (should (string-suffix-p "/text" (acurl-response-url r)))
    (should (equal (acurl-response-body r) "héllo wörld")))
  (let ((out (acurl-test--run (acurl-test--url "/redirect/3") :max-redirects 2)))
    (should (eq (car out) 'error))
    (should (eq (acurl-error-type (cdr out)) 'curl))
    (should (= (acurl-error-code (cdr out)) 47))))

(defun acurl-test--redirect-url (target &optional status)
  "Return a test server URL redirecting to TARGET with STATUS."
  (acurl-test--url (format "/redirect-to?status=%s&url=%s"
                           (or status 302) (url-hexify-string target))))

(defun acurl-test--echo (url &rest args)
  "Return the request seen by the /echo endpoint at the end of URL.
ARGS are passed to `acurl-request'."
  (let ((json-object-type 'alist))
    (json-read-from-string
     (acurl-response-body (cdr (apply #'acurl-test--run url args))))))

(ert-deftest acurl-test-redirect-cross-origin-headers ()
  (acurl-test--ensure-server)
  (let ((headers '(("Authorization" . "Bearer S3CRET") ("X-Api-Key" . "S3CRET")
                   ("Accept" . "application/json")))
        (other (format "http://localhost:%s/echo" acurl-test--port)))
    (let ((h (alist-get 'headers (acurl-test--echo (acurl-test--redirect-url "/echo")
                                                   :headers headers))))
      (should (equal (alist-get 'authorization h) "Bearer S3CRET"))
      (should (equal (alist-get 'x-api-key h) "S3CRET")))
    (let ((h (alist-get 'headers (acurl-test--echo (acurl-test--redirect-url other)
                                                   :headers headers))))
      (should-not (alist-get 'authorization h))
      (should-not (alist-get 'x-api-key h))
      (should-not (equal (alist-get 'accept h) "application/json")))
    ;; Back on the original origin, the headers are sent again.
    (let ((h (alist-get 'headers (acurl-test--echo
                                  (acurl-test--redirect-url
                                   (format "http://localhost:%s/redirect-to?url=%s"
                                           acurl-test--port
                                           (url-hexify-string (acurl-test--url "/echo"))))
                                  :headers headers))))
      (should (equal (alist-get 'x-api-key h) "S3CRET")))
    (let* ((acurl-redirect-headers '("accept" "X-Api-Key"))
           (h (alist-get 'headers (acurl-test--echo (acurl-test--redirect-url other)
                                                    :headers headers))))
      (should-not (alist-get 'authorization h))
      (should (equal (alist-get 'x-api-key h) "S3CRET"))
      (should (equal (alist-get 'accept h) "application/json")))))

(ert-deftest acurl-test-redirect-protocols ()
  (dolist (target '("file:///etc/passwd" "ftp://127.0.0.1/x"))
    (let ((out (acurl-test--run (acurl-test--redirect-url target))))
      (should (eq (car out) 'error))
      (should (eq (acurl-error-type (cdr out)) 'curl))
      (should (= (acurl-error-code (cdr out)) 1)))))

(ert-deftest acurl-test-redirect-methods ()
  (pcase-dolist (`(,method ,status ,new-method ,new-body)
                 '(("POST" 302 "GET" "") ("POST" 303 "GET" "")
                   ("POST" 307 "POST" "data") ("POST" 308 "POST" "data")
                   ("PUT" 302 "PUT" "data") ("PUT" 303 "GET" "")))
    (let ((echo (acurl-test--echo (acurl-test--redirect-url "/echo" status)
                                  :method method :body "data")))
      (should (equal (list method status (alist-get 'method echo) (alist-get 'body echo))
                     (list method status new-method new-body)))))
  (let ((r (cdr (acurl-test--run (acurl-test--redirect-url "/text" 303) :method "HEAD"))))
    (should (= (acurl-response-status r) 200))
    (should (= (acurl-response-size r) 13))))

(ert-deftest acurl-test-redirect-download ()
  (acurl-test--with-dir dir
    (let ((r (cdr (acurl-test--wait
                   (lambda (ok ko)
                     ;; curl leaves the space of an absolute Location.
                     (acurl-download (acurl-test--redirect-url
                                      (acurl-test--url "/files/a b.txt"))
                                     dir
                                     :on-success ok :on-error ko))))))
      (should (equal (acurl-response-file r) (expand-file-name "a b.txt" dir)))
      (should (= (acurl-response-redirects r) 1))
      (should (equal (acurl--read-file (acurl-response-file r)) "file body")))))

(ert-deftest acurl-test-http-errors ()
  (let ((out (acurl-test--run (acurl-test--url "/status/404"))))
    (should (eq (car out) 'error))
    (should (eq (acurl-error-type (cdr out)) 'http))
    (should (= (acurl-error-code (cdr out)) 404))
    (should (equal (acurl-response-body (acurl-error-response (cdr out))) "status body")))
  (let ((out (acurl-test--run (acurl-test--url "/status/404") :http-errors nil)))
    (should (eq (car out) 'success))
    (should (= (acurl-response-status (cdr out)) 404))))

(ert-deftest acurl-test-connection-error ()
  (let ((out (acurl-test--run "http://127.0.0.1:1/" :max-attempts 1)))
    (should (eq (car out) 'error))
    (should (eq (acurl-error-type (cdr out)) 'curl))
    (should (= (acurl-error-code (cdr out)) 7))
    (should (stringp (acurl-error-message (cdr out))))))

(ert-deftest acurl-test-default-error-message-hides-secrets ()
  (let (logged)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (when format (push (apply #'format-message format args) logged)))))
      (acurl-request "http://user:S3CRET@127.0.0.1:1/S3CRET?token=S3CRET" :max-attempts 1)
      (with-timeout (10 (error "No error message"))
        (while (not (cl-some (lambda (m) (string-prefix-p "acurl:" m)) logged))
          (accept-process-output nil 0.05))))
    (let ((m (cl-find-if (lambda (m) (string-prefix-p "acurl:" m)) logged)))
      (should (string-match-p "127\\.0\\.0\\.1" m))
      (should-not (string-match-p "S3CRET" m)))))

(ert-deftest acurl-test-max-body-size ()
  (let ((acurl-max-body-size 1000))
    (should (= (acurl-response-size (cdr (acurl-test--run (acurl-test--url "/size/1000"))))
               1000))
    (dolist (path '("/size/1001" "/chunked/100000"))
      (let ((out (acurl-test--run (acurl-test--url path))))
        (should (eq (car out) 'error))
        (should (eq (acurl-error-type (cdr out)) 'curl))
        (should (= (acurl-error-code (cdr out)) 63))))
    ;; HEAD reports the size, downloads go to disk.
    (should (= (acurl-response-size
                (cdr (acurl-test--run (acurl-test--url "/size/5000") :method "HEAD")))
               5000))
    (acurl-test--with-dir dir
      (should (= (acurl-response-size
                  (cdr (acurl-test--wait
                        (lambda (ok ko)
                          (acurl-download (acurl-test--url "/chunked/5000") dir
                                          :on-success ok :on-error ko)))))
                 5000))))
  (let ((acurl-max-body-size nil))
    (should (= (acurl-response-size (cdr (acurl-test--run (acurl-test--url "/chunked/100000"))))
               100000))))

(ert-deftest acurl-test-max-body-size-unknown-length ()
  ;; curl before 8.4 does not stop a body of unknown size.
  (let* ((file (make-temp-file "acurl-test-body-" nil nil (make-string 2000 ?x)))
         (req (acurl--make-req :url "http://h/" :method "GET" :max-attempts 1
                               :body-file file :max-body-size 1000))
         result)
    (setf (acurl--req-on-error req) (lambda (e) (setq result e)))
    (acurl--handle-exit req 0 '((http_code . 200)) nil)
    (should (eq (acurl-error-type result) 'curl))
    (should (= (acurl-error-code result) 63))
    (should-not (file-exists-p file))))

(ert-deftest acurl-test-method-headers-body ()
  (let* ((r (cdr (acurl-test--run (acurl-test--url "/echo")
                                  :method "post"
                                  :headers '(("X-Custom" . "v1") (X-Sym . "v2")
                                             ("Content-Type" . "application/json"))
                                  :body "{\"a\":\"é\"}")))
         (json-object-type 'alist)
         (echo (json-read-from-string (acurl-response-body r))))
    (should (equal (alist-get 'method echo) "POST"))
    (should (equal (alist-get 'x-custom (alist-get 'headers echo)) "v1"))
    (should (equal (alist-get 'x-sym (alist-get 'headers echo)) "v2"))
    (should (equal (alist-get 'content-type (alist-get 'headers echo)) "application/json"))
    (should (equal (alist-get 'body echo) "{\"a\":\"é\"}")))
  (let* ((json-object-type 'alist))
    (dolist (method '("PUT" "PATCH" "DELETE" "GET"))
      (let ((echo (json-read-from-string
                   (acurl-response-body
                    (cdr (acurl-test--run (acurl-test--url "/echo") :method method))))))
        (should (equal (alist-get 'method echo) method)))))
  (let ((r (cdr (acurl-test--run (acurl-test--url "/text") :method "HEAD"))))
    (should (= (acurl-response-status r) 200))
    (should (equal (acurl-response-body r) ""))
    (should (= (acurl-response-size r) 13)))
  (let ((r (cdr (acurl-test--run (acurl-test--url "/nolength") :method "HEAD"))))
    (should (= (acurl-response-status r) 200))
    (should-not (acurl-response-size r))))

(ert-deftest acurl-test-secrets-not-in-argv ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((secret "S3CRET")
            (tricky "a\\\" --output /tmp/acurl-pwn \"\\")
            (auth (list (cons "Authorization" (concat "Bearer " secret))))
            (commands nil)
            (record (lambda (&rest args)
                      (when (equal (plist-get args :name) "acurl")
                        (push (plist-get args :command) commands)))))
       (acurl-test--ensure-server)
       (advice-add 'make-process :before record)
       (unwind-protect
           (let* ((key (acurl-test--key))
                  (echo (cdr (acurl-test--run
                              (acurl-test--url (concat "/echo?token=" secret))
                              :headers (cons (cons "X-Tricky" tricky) auth))))
                  (redirect (cdr (acurl-test--run
                                  (acurl-test--url (concat "/redirect/2?token=" secret))
                                  :headers auth)))
                  (retry (cdr (acurl-test--run
                               (acurl-test--url (format "/fail-then-ok/%s/1/502?token=%s"
                                                        key secret))
                               :headers auth)))
                  (resume (cdr (acurl-test--wait
                                (lambda (ok ko)
                                  (acurl-download
                                   (acurl-test--url (format "/resumable/%s?token=%s"
                                                            (acurl-test--key) secret))
                                   dir :headers auth :on-success ok :on-error ko)))))
                  (json-object-type 'alist))
             (should (equal (alist-get 'x-tricky
                                       (alist-get 'headers
                                                  (json-read-from-string
                                                   (acurl-response-body echo))))
                            tricky))
             (should (= (acurl-response-redirects redirect) 2))
             (should (= (acurl-response-attempts retry) 2))
             (should (= (acurl-response-attempts resume) 2))
             (should (= (length commands) 8))
             (dolist (command commands)
               (should-not (cl-some (lambda (arg) (string-match-p secret arg)) command))))
         (advice-remove 'make-process record))
       (should-not (file-exists-p "/tmp/acurl-pwn"))))))

(ert-deftest acurl-test-retry-after-seconds ()
  (let* ((key (acurl-test--key))
         (start (float-time))
         (r (cdr (acurl-test--run (acurl-test--url (format "/retry-after/%s/seconds" key))))))
    (should (= (acurl-response-status r) 200))
    (should (= (acurl-response-attempts r) 2))
    (should (>= (- (float-time) start) 0.9))))

(ert-deftest acurl-test-retry-after-date ()
  (let* ((key (acurl-test--key))
         (r (cdr (acurl-test--run (acurl-test--url (format "/retry-after/%s/date" key))))))
    (should (= (acurl-response-status r) 200))
    (should (= (acurl-response-attempts r) 2))))

(ert-deftest acurl-test-retry-after-unrepresentable ()
  (should-not (acurl--parse-retry-after "Wed, 21 Oct 99999999999 07:28:00 GMT"))
  (acurl-test--fast-retries
   (let* ((key (acurl-test--key))
          (r (cdr (acurl-test--run
                   (acurl-test--url (format "/retry-after/%s/unrepresentable" key))))))
     (should (= (acurl-response-status r) 200))
     (should (= (acurl-response-attempts r) 2)))))

(ert-deftest acurl-test-retry-after-cap ()
  (let* ((key (acurl-test--key))
         (acurl-retry-after-max 0)
         (start (float-time))
         (r (cdr (acurl-test--run (acurl-test--url (format "/retry-after/%s/seconds" key))))))
    (should (= (acurl-response-status r) 200))
    (should (< (- (float-time) start) 0.9))))

(ert-deftest acurl-test-retry-backoff ()
  (acurl-test--fast-retries
   (let* ((key (acurl-test--key))
          (r (cdr (acurl-test--run (acurl-test--url (format "/fail-then-ok/%s/2/502" key))))))
     (should (= (acurl-response-status r) 200))
     (should (= (acurl-response-attempts r) 3)))
   (let* ((key (acurl-test--key))
          (out (acurl-test--run (acurl-test--url (format "/fail-then-ok/%s/5/500" key))
                                :max-attempts 2)))
     (should (eq (car out) 'error))
     (should (= (acurl-error-code (cdr out)) 500))
     (should (= (acurl-response-attempts (acurl-error-response (cdr out))) 2)))))

(ert-deftest acurl-test-no-retry ()
  (acurl-test--fast-retries
   ;; 404 is not transient.
   (let ((key (acurl-test--key)))
     (acurl-test--run (acurl-test--url (format "/fail-then-ok/%s/1/404" key)))
     (should (equal (acurl-response-body
                     (cdr (acurl-test--run (acurl-test--url (format "/count/%s" key)))))
                    "1")))
   ;; POST is not retried on 500, only on 429/503.
   (let ((key (acurl-test--key)))
     (acurl-test--run (acurl-test--url (format "/fail-then-ok/%s/1/500" key)) :method "POST")
     (should (equal (acurl-response-body
                     (cdr (acurl-test--run (acurl-test--url (format "/count/%s" key)))))
                    "1")))
   (let ((key (acurl-test--key)))
     (should (eq (car (acurl-test--run (acurl-test--url (format "/fail-then-ok/%s/1/503" key))
                                       :method "POST"))
                 'success)))))

(ert-deftest acurl-test-timeout ()
  (let ((out (acurl-test--run (acurl-test--url "/slow/3") :timeout 0.5 :max-attempts 1)))
    (should (eq (car out) 'error))
    (should (eq (acurl-error-type (cdr out)) 'timeout))
    (should (= (acurl-error-code (cdr out)) 28)))
  (acurl-test--fast-retries
   (let* ((key (acurl-test--key))
          (r (cdr (acurl-test--run (acurl-test--url (format "/slow-once/%s/3" key))
                                   :timeout 0.5))))
     (should (equal (acurl-response-body r) "fast"))
     (should (= (acurl-response-attempts r) 2)))))

(ert-deftest acurl-test-cancel ()
  (dolist (delay '(0 0.3))
    (let* (h
           (out (acurl-test--wait
                 (lambda (ok ko)
                   (setq h (acurl-request (acurl-test--url "/slow/3")
                                          :on-success ok :on-error ko))
                   (if (zerop delay)
                       (acurl-cancel h)
                     (run-at-time delay nil #'acurl-cancel h))))))
      (should (eq (car out) 'error))
      (should (eq (acurl-error-type (cdr out)) 'cancelled))))
  ;; Cancel during a retry wait.
  (let* ((key (acurl-test--key))
         h
         (out (acurl-test--wait
               (lambda (ok ko)
                 (setq h (acurl-request
                          (acurl-test--url (format "/retry-after/%s/seconds" key))
                          :on-success ok :on-error ko))
                 (run-at-time 0.5 nil #'acurl-cancel h)))))
    (should (eq (acurl-error-type (cdr out)) 'cancelled)))
  (should (= acurl--active 0))
  (should-not acurl--queue))

(ert-deftest acurl-test-concurrency ()
  (let ((acurl-max-concurrent 2)
        (results nil)
        (max-seen 0))
    (dotimes (_ 5)
      (acurl-request (acurl-test--url "/slow/0.3")
                     :on-success (lambda (r) (push r results))
                     :on-error (lambda (e) (push e results))))
    (with-timeout (20 (error "Requests did not complete"))
      (while (< (length results) 5)
        (setq max-seen (max max-seen acurl--active))
        (accept-process-output nil 0.02)))
    (should (= max-seen 2))
    (should (cl-every #'acurl-response-p results))))

(ert-deftest acurl-test-download-content-disposition ()
  (acurl-test--with-dir dir
    (let* ((cd (url-hexify-string
                "attachment; filename=\"x.bin\"; filename*=UTF-8''%C3%A9t%C3%A9.txt"))
           (r (cdr (acurl-test--wait
                    (lambda (ok ko)
                      (acurl-download (acurl-test--url (concat "/cd?v=" cd)) dir
                                      :on-success ok :on-error ko))))))
      (should (= (acurl-response-status r) 200))
      (should (equal (acurl-response-file r) (expand-file-name "été.txt" dir)))
      (should (= (acurl-response-size r) 7))
      (should (equal (acurl-response-content-type r) "application/octet-stream"))
      (should (equal (acurl--read-file (acurl-response-file r)) "cd body"))
      (should (equal (directory-files dir nil "\\`[^.]") '("été.txt"))))))

(ert-deftest acurl-test-download-unsafe-name-and-unique ()
  (acurl-test--with-dir dir
    (let ((url (acurl-test--url
                (concat "/cd?v=" (url-hexify-string "attachment; filename=\"../../evil.sh\"")))))
      (dotimes (_ 3)
        (acurl-test--wait (lambda (ok ko) (acurl-download url dir :on-success ok :on-error ko))))
      (should (equal (directory-files dir nil "\\`[^.]")
                     '("evil-1.sh" "evil-2.sh" "evil.sh")))
      (acurl-test--wait (lambda (ok ko)
                          (acurl-download url dir :overwrite t :on-success ok :on-error ko)))
      (should (= (length (directory-files dir nil "\\`[^.]")) 3)))))

(ert-deftest acurl-test-download-never-follows-symlink ()
  (acurl-test--with-dir dir
    (let ((victim (concat dir "victim"))
          (url (acurl-test--url
                (concat "/cd?v=" (url-hexify-string "attachment; filename=\"link\"")))))
      (write-region "keep" nil victim nil 'silent)
      (make-symbolic-link victim (concat dir "link"))
      (acurl-test--wait (lambda (ok ko) (acurl-download url dir :on-success ok :on-error ko)))
      (should (equal (acurl--read-file (concat dir "link-1")) "cd body"))
      (acurl-test--wait (lambda (ok ko)
                          (acurl-download url dir :overwrite t :on-success ok :on-error ko)))
      (should-not (file-symlink-p (concat dir "link")))
      (should (equal (acurl--read-file (concat dir "link")) "cd body"))
      (should (equal (acurl--read-file victim) "keep")))))

(ert-deftest acurl-test-download-url-name-and-file ()
  (acurl-test--with-dir dir
    (let ((r (cdr (acurl-test--wait
                   (lambda (ok ko)
                     (acurl-download (acurl-test--url "/files/report%20v1.txt?x=1") dir
                                     :on-success ok :on-error ko))))))
      (should (equal (acurl-response-file r) (expand-file-name "report v1.txt" dir))))
    (let ((r (cdr (acurl-test--wait
                   (lambda (ok ko)
                     (acurl-download (acurl-test--url "/text") (concat dir "named.out")
                                     :on-success ok :on-error ko))))))
      (should (equal (acurl-response-file r) (expand-file-name "named.out" dir))))
    (let ((r (cdr (acurl-test--wait
                   (lambda (ok ko)
                     (acurl-download (acurl-test--url "/") dir
                                     :http-errors nil :on-success ok :on-error ko))))))
      (should (eq (acurl-error-type r) 'http)))
    (should-not (directory-files dir nil "\\.part\\'"))))

(ert-deftest acurl-test-download-resume ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((key (acurl-test--key))
            (r (cdr (acurl-test--wait
                     (lambda (ok ko)
                       (acurl-download (acurl-test--url (format "/resumable/%s" key)) dir
                                       :on-success ok :on-error ko))))))
       (should (= (acurl-response-status r) 206))
       (should (= (acurl-response-attempts r) 2))
       (should (= (acurl-response-size r) 102400))
       (should (equal (acurl-response-file r) (expand-file-name "resumed.bin" dir)))
       (should (equal (acurl--read-file (acurl-response-file r))
                      (acurl-test--payload)))
       (should (equal (acurl-test--get-json (format "/ranges/%s" key))
                      '(nil "bytes=51200-")))))))

(ert-deftest acurl-test-download-range-ignored ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((key (acurl-test--key))
            (r (cdr (acurl-test--wait
                     (lambda (ok ko)
                       (acurl-download (acurl-test--url (format "/norange/%s" key))
                                       (concat dir "out.bin")
                                       :on-success ok :on-error ko))))))
       (should (= (acurl-response-status r) 200))
       (should (= (acurl-response-size r) 102400))
       (should (equal (acurl--read-file (acurl-response-file r)) (acurl-test--payload)))
       ;; Truncated, resumed but ignored, restarted without range.
       (should (equal (acurl-test--get-json (format "/ranges/%s" key))
                      '(nil "bytes=51200-" nil)))))))

(ert-deftest acurl-test-download-range-rejected ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((key (acurl-test--key))
            (r (cdr (acurl-test--wait
                     (lambda (ok ko)
                       (acurl-download (acurl-test--url (format "/range416/%s" key))
                                       (concat dir "out.bin")
                                       :on-success ok :on-error ko))))))
       (should (= (acurl-response-status r) 200))
       (should (equal (acurl--read-file (acurl-response-file r)) (acurl-test--payload)))
       (should (equal (acurl-test--get-json (format "/ranges/%s" key))
                      '(nil "bytes=51200-" nil)))))))

(ert-deftest acurl-test-download-resource-changed ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((key (acurl-test--key))
            (r (cdr (acurl-test--wait
                     (lambda (ok ko)
                       (acurl-download (acurl-test--url (format "/changed/%s" key))
                                       (concat dir "out.bin")
                                       :on-success ok :on-error ko))))))
       (should (= (acurl-response-status r) 200))
       (should (equal (acurl--read-file (acurl-response-file r))
                      (reverse (acurl-test--payload))))
       (should (equal (acurl-test--get-json (format "/ranges/%s" key))
                      '((nil nil) ("bytes=51200-" "\"v1\"") (nil nil))))))))

(ert-deftest acurl-test-download-416-without-resume ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((key (acurl-test--key))
            (out (acurl-test--wait
                  (lambda (ok ko)
                    (acurl-download (acurl-test--url (format "/fail-then-ok/%s/1/416" key))
                                    dir :on-success ok :on-error ko)))))
       (should (eq (car out) 'error))
       (should (= (acurl-error-code (cdr out)) 416))
       (should (equal (acurl-response-body
                       (cdr (acurl-test--run (acurl-test--url (format "/count/%s" key)))))
                      "1"))))))

(ert-deftest acurl-test-download-resume-after-error-status ()
  (acurl-test--fast-retries
   (acurl-test--with-dir dir
     (let* ((key (acurl-test--key))
            (r (cdr (acurl-test--wait
                     (lambda (ok ko)
                       (acurl-download (acurl-test--url (format "/resume-503/%s" key))
                                       (concat dir "out.bin")
                                       :on-success ok :on-error ko))))))
       (should (= (acurl-response-attempts r) 3))
       (should (equal (acurl--read-file (acurl-response-file r)) (acurl-test--payload)))
       (should (equal (acurl-test--get-json (format "/ranges/%s" key))
                      '(nil "bytes=51200-" "bytes=51200-")))))))

(ert-deftest acurl-test-download-failure-cleans-partial ()
  (acurl-test--with-dir dir
    (let ((out (acurl-test--wait
                (lambda (ok ko)
                  (acurl-download (acurl-test--url "/status/403") dir
                                  :on-success ok :on-error ko)))))
      (should (eq (acurl-error-type (cdr out)) 'http))
      (should (= (acurl-error-code (cdr out)) 403))
      (should-not (directory-files dir nil "\\`[^.]\\|\\.part\\'")))
    (let* (h
           (out (acurl-test--wait
                 (lambda (ok ko)
                   (setq h (acurl-download (acurl-test--url "/slow/3") dir
                                           :on-success ok :on-error ko))
                   (run-at-time 0.3 nil #'acurl-cancel h)))))
      (should (eq (acurl-error-type (cdr out)) 'cancelled))
      (should-not (directory-files dir nil "\\.part\\'")))))

(provide 'acurl-test)
;;; acurl-test.el ends here
