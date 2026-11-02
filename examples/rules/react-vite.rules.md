# Repository rules — React single-page app (Vite)

This repository is a React 18/19 single-page app in TypeScript, built with Vite. All code runs in the browser. Review `.ts`, `.tsx` and `vite.config.*` changes according to the rules below.

## React rules

### Secrets and the browser boundary

1. Everything in the bundle is public. A secret (an API key for a paid or privileged service, a client secret, a signing key) in source, in a `VITE_*` variable, or injected with `define` in `vite.config` is CRITICAL. Calls that need one belong on a server.
2. Reading a non-`VITE_` variable through `import.meta.env` or `process.env` in app code is WARNING: it is `undefined` at runtime.
3. Storing access or refresh tokens in `localStorage` or `sessionStorage` is WARNING when the rest of the app uses cookies.

### Injection

1. `dangerouslySetInnerHTML` with data that is not passed through a sanitiser (such as DOMPurify) is CRITICAL.
2. An `href`, `src` or `window.location` value built from user or API data without restricting it to `http(s):` or a relative path is WARNING (`javascript:` URLs).
3. `window.open` or `target="_blank"` to an external URL without `rel="noopener noreferrer"` is SUGGESTION.

### Hooks and effects

1. A hook called conditionally, in a loop, or after an early return breaks the rules of hooks and is WARNING.
2. An effect that sets state from an async call needs a way to ignore stale results (an `AbortController` or an `ignore` flag in the cleanup). A missing one is WARNING when the input can change while the request is in flight.
3. Every listener, subscription, interval, timer or observer added in an effect needs cleanup (WARNING).
4. A dependency array that leaves out a value the effect or callback reads is WARNING when it leads to stale data. Do not flag what `eslint-plugin-react-hooks` already reports.
5. Copying props into state, or computing derived values in an effect, is SUGGESTION; compute them during render.

### State and rendering

1. Mutating state or props in place (`push`, `splice`, property assignment, `sort` on the state array) and then setting it is WARNING: React may not re-render.
2. Using the array index as `key` in a list that can be reordered, filtered or edited is WARNING.
3. Calling `setState` during render outside an event handler or effect is WARNING.

### Data fetching

1. A `fetch` whose response is used without checking `res.ok` (or the client's error path) is WARNING.
2. An unawaited promise whose failure would be lost is WARNING, unless it has its own `.catch`.
3. A type assertion (`as Something`) on API data without a runtime check is SUGGESTION, unless the value then reaches `dangerouslySetInnerHTML`, a URL or a security decision (WARNING).

### Build configuration

1. `build.sourcemap: true` for production, `server.host: true` or `0.0.0.0` committed for all environments, or a dev `proxy` that points at a production API is WARNING.

## Conventions to respect

Formatting, import order, unused code and hook dependency lint are enforced by Prettier, ESLint and the TypeScript compiler; do not comment on them. Do not suggest `useMemo` or `useCallback` unless the diff shows a real cost.
