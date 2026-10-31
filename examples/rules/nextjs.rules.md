# Repository rules — Next.js (App Router) web app

This repository is a Next.js App Router application using React Server and Client Components and TypeScript. Review TypeScript/TSX changes according to the rules below.

## Next.js / React rules

### Server and Client Component boundaries

1. A secret or server-only value (API keys, tokens, connection strings, anything read from a non-`NEXT_PUBLIC_` env var) passed as a prop into a `'use client'` component is CRITICAL: it is serialised into the browser bundle.
2. `NEXT_PUBLIC_*` variables are inlined at build time. Flag code that expects to change one at runtime (WARNING).
3. Flag browser-only APIs (`window`, `document`, `localStorage`) used in a Server Component or during server render without a guard (WARNING).

### Data fetching and route handlers

1. Route handlers and server actions must validate every input (params, query, body) before it reaches a database query, a file path or an upstream URL. Missing validation on a value that controls a path or URL is CRITICAL.
2. An expected failure returns an explicit status, never a raw error or stack trace.

### Async and error handling

1. Every unawaited promise is a bug risk: flag a floating promise unless it is clearly fire-and-forget with its own `.catch` (WARNING).
2. Every listener, subscription, interval or timer added in an effect needs cleanup (WARNING).

### Type safety

1. Flag `as SomeType` assertions or `JSON.parse` results used without a runtime check on data from outside the app (WARNING).

## Conventions to respect

Formatting and import order are enforced by Prettier and ESLint; do not comment on them. Follow the patterns already used in the surrounding code over generic style preferences.
