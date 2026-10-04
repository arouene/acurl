# acurl

Asynchronous HTTP client for Emacs built on curl. It fetches response bodies
and downloads files without blocking Emacs, with retries, Retry-After,
resumable downloads, timeouts, custom headers and Content-Disposition file
naming.

Requirements: Emacs 28.1 or later, curl 7.75 or later.

## Usage

```elisp
(require 'acurl)

;; Fetch a body.
(acurl-request "https://example.com/api/items"
  :headers '(("Accept" . "application/json")
             ("Authorization" . "Bearer TOKEN"))
  :on-success (lambda (r)
                (message "%d %s, %d bytes: %s"
                         (acurl-response-status r)
                         (acurl-response-content-type r)
                         (acurl-response-size r)
                         (acurl-response-body r)))
  :on-error (lambda (e)
              (message "Failed (%s %s): %s"
                       (acurl-error-type e)
                       (acurl-error-code e)
                       (acurl-error-message e))))

;; POST a JSON body.
(acurl-request "https://example.com/api/items"
  :method "POST"
  :headers '(("Content-Type" . "application/json"))
  :body (json-encode '((name . "été")))
  :on-success (lambda (r) (message "Created: %d" (acurl-response-status r))))

;; Download into a directory: the file is named after Content-Disposition,
;; else the last URL path segment, else `acurl-default-filename'.
(acurl-download "https://example.com/export?id=42" "~/Downloads/"
  :on-success (lambda (r) (message "Saved %s" (acurl-response-file r))))

;; Download to an explicit file name, and cancel it.
(let ((handle (acurl-download "https://example.com/big.iso" "/tmp/big.iso"
                              :timeout nil)))
  (acurl-cancel handle))
```

## API

### `(acurl-request URL &key ...)`

Starts the request and returns a handle for `acurl-cancel`. Only `http://` and
`https://` URLs are accepted. Keyword arguments:

| Keyword            | Default                     | Meaning                                                               |
|--------------------|-----------------------------|-----------------------------------------------------------------------|
| `:method`          | `"GET"`                     | `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, ...                  |
| `:headers`         | `nil`                       | Alist of `(NAME . VALUE)`; an empty value sends an empty header       |
| `:body`            | `nil`                       | Request body string, multibyte strings are encoded as UTF-8           |
| `:output`          | `nil`                       | Directory or file name: turns the request into a download             |
| `:on-success`      | `ignore`                    | Called with an `acurl-response`                                       |
| `:on-error`        | display the message         | Called with an `acurl-error`                                          |
| `:connect-timeout` | `acurl-connect-timeout`     | Seconds to establish the connection                                   |
| `:timeout`         | `acurl-timeout`             | Maximum seconds per attempt, `nil` for none                           |
| `:max-attempts`    | `acurl-max-attempts`        | Attempts including the first                                          |
| `:max-redirects`   | `acurl-max-redirects`       | Redirects followed                                                    |
| `:http-errors`     | `acurl-http-errors`         | Whether status 400 and above goes to `:on-error` (body requests only) |
| `:overwrite`       | `acurl-download-overwrite`  | Whether a download may replace an existing file                       |
| `:extra-args`      | `nil`                       | Extra curl arguments (proxy, TLS options, ...)                        |

`POST`, `PUT` and `PATCH` send an empty body when `:body` is nil. curl sends
`Content-Type: application/x-www-form-urlencoded` with a body unless a
`Content-Type` header is given.

### `(acurl-download URL OUTPUT &rest ARGS)`

Same as `(acurl-request URL :output OUTPUT ...)`. `OUTPUT` is a directory when
it exists as one or ends with a slash, else a file name. The response `file`
slot holds the absolute path of the saved file.

### `(acurl-cancel HANDLE)`

Stops a queued, running or waiting request. Its `:on-error` callback receives
an error of type `cancelled`.

### `acurl-response`

| Accessor                        | Value                                                      |
|---------------------------------|------------------------------------------------------------|
| `acurl-response-status`         | Final HTTP status, after redirects                         |
| `acurl-response-url`            | Final URL                                                  |
| `acurl-response-content-type`   | Content-Type of the final response                         |
| `acurl-response-size`           | Body size in bytes, size of the saved file, or for `HEAD` the announced Content-Length (`nil` when absent) |
| `acurl-response-headers`        | Alist `(LOWERCASE-NAME . VALUE)` of the final response     |
| `acurl-response-body`           | Body string (body requests), `nil` for downloads           |
| `acurl-response-file`           | Absolute path of the saved file (downloads)                |
| `acurl-response-redirects`      | Number of redirects followed                               |
| `acurl-response-attempts`       | Number of attempts made                                    |
| `(acurl-response-header R NAME)`| First value of header NAME, case insensitive               |

The body is decoded with the Content-Type charset, as UTF-8 for textual types
without one (`text/*`, JSON, XML, JavaScript), and is left as a unibyte string
otherwise.

### `acurl-error`

| Accessor               | Value                                                                    |
|------------------------|--------------------------------------------------------------------------|
| `acurl-error-type`     | `curl` (transport), `timeout`, `http` (status >= 400) or `cancelled`     |
| `acurl-error-code`     | curl exit code for `curl` and `timeout`, HTTP status for `http`          |
| `acurl-error-message`  | Human readable message                                                   |
| `acurl-error-response` | `acurl-response` when a response was received, with the body for `http` |

## Behavior

**Retries.** Transient failures are retried up to `:max-attempts` times:
curl exit codes in `acurl-retry-curl-exit-codes` (connection failures,
timeouts, truncated transfers) and statuses in `acurl-retry-statuses` (408,
429, 500, 502, 503, 504). The delay doubles from `acurl-retry-base-delay` up to
`acurl-retry-max-delay`, with random jitter. A `Retry-After` header, in
delta-seconds or HTTP-date form, replaces the backoff, capped at
`acurl-retry-after-max`. Methods outside `acurl-idempotent-methods` (such as
`POST`) are only retried when the server certainly did not process the
request: connection failures and status 429 or 503. Retries wait on Emacs
timers and never block.

**Resume.** A download writes to a hidden `.acurl-*.part` file next to its
destination. A retry resumes it with a range request, guarded by `If-Range`
with the ETag (or Last-Modified) of the first response. If the server ignores
the range or the resource changed (200 instead of 206), or the server rejects
the range (416), the download restarts from scratch. On success the file is renamed atomically to its final name; on
failure or cancellation it is removed. Downloads always treat status 400 and
above as an error, and error bodies never reach the file.

**File names.** In directory mode the name comes from the Content-Disposition
`filename*` (RFC 5987) or `filename` parameter, then the last path segment of
the final URL, then `acurl-default-filename`. Path components, control
characters and leading dots are stripped. An existing file is never replaced
unless `:overwrite` is non-nil: `name-1.ext`, `name-2.ext`, ... are used
instead. This also applies to explicit file names.

**Concurrency.** At most `acurl-max-concurrent` curl processes run at once;
other requests wait in a queue.

**Safety.** curl runs without a shell, with `~/.curlrc` disabled, URL globbing
off and only HTTP and HTTPS allowed for the URL and redirects. Header names
must be valid tokens and header values cannot contain line breaks. Metadata
comes from curl `--write-out '%{json}'` on stdout while the body goes to a
file, so a body can never corrupt the metadata.

The `acurl` customization group (`M-x customize-group RET acurl`) holds every
default, including `acurl-curl-program` and `acurl-extra-args`.

## Development

```sh
make          # byte-compile (warnings are errors), checkdoc, tests
make test     # ERT tests only
```

Integration tests start `test/server.py` (Python 3) on an ephemeral local port.
