# Repository rules — Angular app

This repository is an Angular 17+ application in TypeScript, with standalone components, signals, RxJS and `HttpClient`, and optionally server-side rendering. Review `.ts` and `.html` template changes according to the rules below.

## Angular rules

### Security

1. `DomSanitizer.bypassSecurityTrustHtml`, `…Url`, `…ResourceUrl`, `…Script` or `…Style` on a value that is not a constant is CRITICAL: it turns off Angular's XSS protection for that value.
2. Writing HTML through the DOM (`nativeElement.innerHTML`, `insertAdjacentHTML`, `Renderer2.setProperty(el, 'innerHTML', …)`) with data that is not a constant is CRITICAL.
3. An HTTP interceptor that adds credentials or a bearer token must check the request URL is our own API. Attaching it to every request is CRITICAL: the token goes to third-party hosts.
4. A secret in `environment*.ts` or any source file is CRITICAL: it ships to the browser.
5. A route guard is a user-experience feature, not access control. A change that relies on `canActivate` alone to protect data the API returns without its own check is WARNING.

### RxJS and subscriptions

1. A `subscribe()` in a component, directive or long-lived service without `takeUntilDestroyed`, the `async` pipe, `toSignal`, or a stored subscription that is unsubscribed is WARNING (memory leak and duplicate work). `HttpClient` calls that complete on their own are exempt.
2. Typeahead or route-param streams that start a request per value need `switchMap` (or explicit cancellation); `mergeMap` or a nested `subscribe` there is WARNING: an older response can overwrite a newer one.
3. An `catchError`-less stream that drives the UI or an effect stops for good after the first error (WARNING).
4. Nested `subscribe` calls are SUGGESTION; compose with operators.

### Signals and change detection

1. Writing to a signal inside `computed()` is WARNING.
2. Mutating an object or array that is an `@Input()` or signal value in place, in an `OnPush` component or a signal, is WARNING: the view does not update. Replace the value instead.
3. A new `@for` with `track $index` over a list that can be reordered or edited is WARNING; track a stable id.

### Server-side rendering

1. Direct use of `window`, `document`, `localStorage` or `navigator` in code that also runs on the server, without `isPlatformBrowser` or `afterNextRender`, is WARNING.

### HTTP and errors

1. A URL or query string built from user input without `HttpParams` or `encodeURIComponent` is WARNING.
2. An error swallowed in `subscribe({ error })` or `catchError(() => EMPTY)` with no user feedback or logging is WARNING.

## Conventions to respect

Formatting and lint are enforced by Prettier and angular-eslint, and the compiler runs with strict templates; do not comment on them. Prefer the patterns already used in the surrounding feature (signals or observables) over generic preferences.
