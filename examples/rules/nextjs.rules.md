# Repository rules — Next.js (App Router)

This repository is a Next.js 15+ App Router application in TypeScript, with React Server Components, Client Components (`'use client'`), Server Actions (`'use server'`) and route handlers (`app/**/route.ts`). Review `.ts`, `.tsx` and `next.config.*` changes according to the rules below.

## Next.js rules

### Server and client boundary

1. A server-only value (an API key, token, connection string, or any `process.env` variable without the `NEXT_PUBLIC_` prefix) passed as a prop to a Client Component, returned from a Server Action, or imported into a `'use client'` module is CRITICAL: it is serialised into the browser.
2. A secret given a `NEXT_PUBLIC_` name is CRITICAL: it is inlined into the client bundle at build time.
3. A module that reads secrets or the database without `import 'server-only'` and is imported from a `'use client'` file is WARNING.

### Server Actions and route handlers

1. Every Server Action is a public HTTP endpoint, whatever page uses it. An action or route handler that changes or reads non-public data without checking the session and that the user may act on that record is CRITICAL.
2. Action and route handler inputs (`FormData`, params, query, JSON body) must be validated (for example with zod) before use. An unvalidated value that reaches a database query, a file path, a shell command or an outgoing URL is CRITICAL; any other unvalidated input is WARNING.
3. Middleware alone is not authorisation. A page, action or route that relies only on `middleware.ts` for access control is WARNING.
4. `redirect()` and `notFound()` work by throwing. Calling them inside a `try` whose `catch` does not rethrow them is WARNING.
5. A `redirect()` to a URL taken from the request without checking it is on our own origin is CRITICAL (open redirect).
6. An expected failure returns an explicit status or error state, never a raw error message or stack trace (WARNING).

### Caching and data

1. Caching per-user or per-request data in a shared cache (`fetch` with `cache: 'force-cache'` or `next: { revalidate }`, `unstable_cache`, `'use cache'`, or `export const dynamic = 'force-static'` on a route that reads cookies, headers or the session) is CRITICAL: one user's data can be served to another.
2. A Server Action that changes data shown on a cached page without `revalidatePath` or `revalidateTag` is WARNING.
3. In Next.js 15 `params`, `searchParams`, `cookies()`, `headers()` and `draftMode()` are async. Reading them without `await` (or `use()` in a Client Component) is WARNING.
4. Independent `await`s in sequence in a Server Component (a request waterfall) are SUGGESTION; use `Promise.all`.

### Client Components

1. Browser-only APIs (`window`, `document`, `localStorage`) used in a Server Component, or during render of a Client Component without a guard, are WARNING.
2. Render output that differs between server and client (`Date.now()`, `Math.random()`, locale formatting without a fixed locale) in a Client Component is WARNING: it causes a hydration mismatch.
3. Every listener, subscription, interval or timer added in `useEffect` needs a cleanup function (WARNING).
4. `dangerouslySetInnerHTML` with data that is not sanitised is CRITICAL.
5. Adding `'use client'` to a layout or page only to make one child interactive is SUGGESTION; move the interactive part into its own component.

### Configuration

1. `images.remotePatterns` with a `**` hostname, or `dangerouslyAllowSVG` without a `contentSecurityPolicy`, is WARNING.
2. Turning off `reactStrictMode`, TypeScript or ESLint errors during build (`ignoreBuildErrors`, `ignoreDuringBuilds`) is WARNING.

### Async, errors and types

1. An unawaited promise whose failure would be lost is WARNING, unless it is clearly fire-and-forget with its own `.catch`.
2. A `catch` that swallows an error without logging, rethrowing or returning an error state is WARNING.
3. A type assertion (`as Something`) or a `JSON.parse` result used without a runtime check on data from outside the app is WARNING.

## Conventions to respect

Formatting, import order and unused code are enforced by Prettier, ESLint and the TypeScript compiler; do not comment on them. Prefer the patterns already used in the surrounding code over generic style preferences.
