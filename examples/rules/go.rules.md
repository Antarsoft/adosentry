# Repository rules — Go service

This repository is a Go 1.22+ service using `net/http` (or a router such as chi), `database/sql` or `pgx`, and `context` for cancellation. Review `.go` changes according to the rules below.

## Go rules

### Security

1. SQL built with `fmt.Sprintf`, `+` or `strings.Builder` from input is CRITICAL; use query parameters.
2. Input passed to `exec.Command` through a shell (`sh -c`, `bash -c`, `cmd /c`) is CRITICAL. Pass arguments separately.
3. Input in a file path (`filepath.Join`, `os.Open`, `http.ServeFile`) without checking the cleaned path stays under the intended root (or using `os.Root`) is CRITICAL.
4. Fetching a URL taken from the request without a host allow-list is CRITICAL (SSRF).
5. Rendering HTML with `text/template`, or converting input to `template.HTML`, `template.JS` or `template.URL`, is CRITICAL.
6. `math/rand` for tokens, ids, passwords or nonces is CRITICAL; use `crypto/rand`.
7. `InsecureSkipVerify: true` outside tests is CRITICAL.
8. A new handler without the auth middleware its siblings use, or a lookup by an id from the request without scoping it to the caller, is CRITICAL.
9. A secret in source, or logging a secret, token or whole request headers, is CRITICAL.

### Errors

1. An error that is ignored (`_ =`, or a call whose error result is dropped) from an operation that can fail and matters (I/O, database, encoding, `Close` on a writer) is WARNING.
2. `:=` inside a block that shadows an outer `err` so the outer one is never set is WARNING.
3. Comparing errors with `==` or a type assertion where the error may be wrapped is WARNING; use `errors.Is` / `errors.As`.
4. Returning an error without context is SUGGESTION; wrap it with `fmt.Errorf("…: %w", err)`.
5. `panic` in library or request-handling code for an expected failure is WARNING.

### Concurrency

1. A map, slice or struct field written from more than one goroutine without a mutex, channel or atomic is WARNING: concurrent map writes crash the process.
2. A goroutine with no way to stop (no `ctx.Done()`, a send on a channel nobody reads) is WARNING (goroutine leak).
3. `wg.Add` called inside the goroutine it counts is WARNING.
4. Copying a struct that contains a `sync.Mutex` or `sync.WaitGroup` (value receivers, passing by value) is WARNING.
5. Loop variables are per-iteration since Go 1.22; do not flag closures that capture them.

### Resources and timeouts

1. An `http.Response.Body`, `sql.Rows`, file or other closer that is not closed on every path is WARNING. After iterating `rows`, `rows.Err()` must be checked (WARNING).
2. `defer` inside a loop that opens resources is WARNING: nothing is released until the function returns.
3. `http.Get`, `http.DefaultClient` or an `http.Client` without `Timeout` for calls to other services is WARNING. An `http.Server` without `ReadHeaderTimeout` is WARNING.

### Context

1. Using `context.Background()` or `context.TODO()` inside request-handling code instead of the request's context is WARNING: cancellation and deadlines are lost.
2. A database or HTTP call in a request path that does not take a context is WARNING.

### Nil safety

1. Writing to a map that may be nil, or dereferencing a pointer that a preceding call can return as nil, is WARNING.
2. Returning a typed nil pointer as an `error` or other interface is WARNING: the result is not `== nil`.

## Conventions to respect

`gofmt`, `go vet` and `golangci-lint` run in CI; do not comment on formatting or on what they already report. Prefer the patterns already used in the surrounding package over generic preferences.
