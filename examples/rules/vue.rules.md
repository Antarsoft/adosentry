# Repository rules — Vue 3 app

This repository is a Vue 3 application in TypeScript, with single-file components using `<script setup>` and the Composition API, Pinia stores and Vue Router, built with Vite. Review `.vue` and `.ts` changes according to the rules below.

## Vue rules

### Security

1. `v-html` (or `innerHTML`) with data that is not passed through a sanitiser such as DOMPurify is CRITICAL.
2. Everything in the bundle is public. A secret in source or in a `VITE_*` variable is CRITICAL.
3. A `:href`, `:src` or `router.push` value built from user or API data without restricting it to `http(s):` or a relative path is WARNING (`javascript:` URLs, open redirects).
4. Compiling a template or running `new Function` / `eval` on user-supplied text is CRITICAL.

### Reactivity

1. Destructuring a `reactive()` object or a Pinia store without `toRefs` / `storeToRefs` loses reactivity (WARNING). Actions may be destructured directly.
2. Destructuring `props` in `<script setup>` on Vue below 3.5, or passing a destructured prop into a composable or `watch` without a getter, loses reactivity (WARNING).
3. Mutating a prop, or an object or array passed in as a prop, is WARNING; emit an event or use `defineModel`.
4. `watch(obj.prop, …)` on a reactive object's property passes a plain value and never fires; use a getter `() => obj.prop` (WARNING).
5. A `computed` with side effects (writing state, calling an API) is WARNING.

### Lifecycle and async

1. Every listener, timer, interval or subscription started in `onMounted`, `setup` or a composable needs cleanup in `onUnmounted` / `onScopeDispose` (WARNING).
2. A `watch` or `watchEffect` that starts an async request must ignore stale results (`onCleanup` / `onWatcherCleanup` with an `AbortController`). A missing guard is WARNING when the source can change while a request is in flight.
3. An unawaited promise whose failure would be lost is WARNING, unless it has its own `.catch`.
4. A `fetch` whose response is used without checking `res.ok` is WARNING.

### Templates and lists

1. `v-for` without a `:key`, or keyed by index on a list that can be reordered or edited, is WARNING.
2. `v-if` and `v-for` on the same element is WARNING: `v-if` runs first in Vue 3 and cannot see the loop variable.

## Conventions to respect

Formatting and lint are enforced by Prettier and eslint-plugin-vue, and types by `vue-tsc`; do not comment on them. Prefer the patterns already used in the surrounding feature over generic preferences.
