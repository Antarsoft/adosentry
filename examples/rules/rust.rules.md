# Repository rules — Rust service

This repository is a Rust (2021 or 2024 edition) service using `tokio`, an HTTP framework such as `axum`, and `sqlx` for the database. Review `.rs`, `Cargo.toml` and migration changes according to the rules below.

## Rust rules

### Unsafe code

1. A new `unsafe` block or `unsafe fn` without a `// SAFETY:` comment that explains why each invariant holds is WARNING.
2. An `unsafe` block whose invariant does not hold for every input is CRITICAL: `slice::from_raw_parts` or pointer arithmetic with a length not checked against the allocation, `transmute` between types with different layouts or validity rules, `get_unchecked` with an unchecked index, or creating two `&mut` to the same data.
3. `unsafe impl Send` or `Sync` for a type holding non-thread-safe data (`Rc`, `RefCell`, raw pointers) is CRITICAL.

### Security

1. SQL built with `format!` or string concatenation and passed to `sqlx::query`, `query_as` or `execute` is CRITICAL; use `query!` / bind parameters.
2. Input passed through a shell (`Command::new("sh").arg("-c")`) is CRITICAL. A file path from input without checking it stays under the intended root is CRITICAL.
3. `danger_accept_invalid_certs(true)` or a no-op certificate verifier outside tests is CRITICAL.
4. A new handler without the auth extractor or middleware layer its siblings use, or a lookup by an id from the request without scoping it to the caller, is CRITICAL.
5. A secret in source, or logging a secret, token or whole request headers (including through `Debug` on a struct that holds one), is CRITICAL.

### Panics and errors

1. `unwrap()`, `expect()`, indexing with `[]`, or `panic!` on a value that depends on input, the network, the file system or the database, in a request path or library code, is WARNING: it panics instead of returning an error.
2. A `Result` that is ignored (`let _ =`, `.ok();` with nothing done) from an operation that can fail and matters is WARNING.
3. An `as` cast that can truncate or change sign (`u64 as u16`, `i64 as usize`) on a value that can exceed the target range is WARNING; use `try_from`.

### Async

1. Blocking calls in async code (`std::fs`, `std::thread::sleep`, blocking HTTP clients, CPU-heavy loops) stall the runtime (WARNING). Use `tokio::fs`, `tokio::time::sleep` or `spawn_blocking`.
2. Holding a `std::sync::Mutex` or `RwLock` guard across an `.await` is WARNING (deadlock, and the future is not `Send`). Release it first or use `tokio::sync::Mutex`.
3. A `tokio::spawn` whose `JoinHandle` is dropped and whose task can fail silently is WARNING.
4. An unbounded channel or queue fed by external input is WARNING (memory growth).

### Resource and API design

1. `RefCell::borrow_mut` that can overlap with another borrow at runtime is WARNING (panic).
2. A public function that takes `String` or `Vec<T>` by value only to read it is SUGGESTION; take `&str` or `&[T]`.
3. Cloning large data in a hot loop to satisfy the borrow checker is SUGGESTION.

## Conventions to respect

`rustfmt` and `clippy` (with warnings denied) run in CI; do not comment on formatting or on what they already report. Prefer the error types and patterns already used in the surrounding crate (`thiserror`, `anyhow`, extractors) over generic preferences.
