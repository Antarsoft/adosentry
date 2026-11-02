# Repository rules — Node.js API (Express)

This repository is a Node.js 20+ HTTP API built with Express 4 or 5, in TypeScript or JavaScript, with a SQL or MongoDB data layer. Review `.ts` and `.js` changes according to the rules below.

## Express rules

### Authentication and authorisation

1. A new route without the auth middleware its sibling routes use is CRITICAL unless it is clearly meant to be public.
2. Loading, changing or deleting a record by an id from the request without scoping it to the current user or tenant is CRITICAL (insecure direct object reference).
3. Using `jwt.decode` for authentication, `jwt.verify` without an `algorithms` list, or accepting `alg: none` is CRITICAL.
4. Session or auth cookies without `httpOnly`, `secure` and `sameSite` are WARNING.
5. CORS that reflects any origin with `credentials: true` is WARNING.

### Injection and untrusted input

1. SQL built with string concatenation or template literals is CRITICAL; use parameters.
2. Passing `req.body`, `req.query` or `req.params` values into a MongoDB filter or update without forcing them to strings or validating them (operator injection such as `{ "$ne": null }`) is CRITICAL.
3. A request value in `child_process.exec`/`execSync`, `eval`, `new Function` or `vm` is CRITICAL. Use `execFile` with an argument array.
4. A request value in a file path (`fs.*`, `res.sendFile`, `res.download`, `path.join`) without resolving it and checking it stays under the intended root is CRITICAL (path traversal).
5. Fetching a URL taken from the request without an allow-list of hosts is CRITICAL (SSRF).
6. Merging `req.body` into an existing object (`Object.assign`, lodash `merge`, spread into a model) is WARNING: it allows prototype pollution or setting fields such as `role`.
7. A body without validation (zod, joi, express-validator, a schema) before use is WARNING.

### Secrets and logging

1. A secret, token or connection string in source is CRITICAL; read it from the environment or a secret store.
2. Logging a password, token, API key, cookie, `Authorization` header, or a whole `req.headers` or `req.body` object is CRITICAL. Logging personal data is WARNING.
3. An error handler that sends `err.message` or `err.stack` to the client is WARNING.

### Request handling

1. A handler that sends a response and then keeps going (a missing `return` after `res.status(…).send()` or `next(err)`) is WARNING: it can send twice or run the rest of the logic.
2. In Express 4, an `async` handler without a `try/catch` that calls `next(err)` (or a wrapper) leaves the request hanging when it throws (WARNING). Express 5 forwards rejections itself.
3. An unawaited promise whose failure would be lost is WARNING, unless it has its own `.catch`.
4. Synchronous file system, `crypto` or `child_process` calls, or CPU-heavy loops over request data, in a request handler block the event loop (WARNING).
5. A list endpoint or query without a limit is WARNING.

### Middleware and hardening

1. Removing `helmet`, a body size limit, or rate limiting on login, sign-up or password-reset routes is WARNING.

## Conventions to respect

Formatting and lint are enforced by Prettier and ESLint; do not comment on them. Prefer the patterns already used in the surrounding router over generic preferences.
