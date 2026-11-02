# Repository rules — NestJS API

This repository is a NestJS 10+ API in TypeScript, with controllers, providers, guards, pipes and an ORM (TypeORM or Prisma). Review `.ts` changes according to the rules below.

## NestJS rules

### Authentication and authorisation

1. A new controller or route without the guard its siblings use (`@UseGuards`, a global guard with `@Public()` opt-outs, roles or API-key guards) is CRITICAL unless it is clearly meant to be public. Adding `@Public()` to a route that reads or changes user data is CRITICAL.
2. A route that loads, changes or deletes a record by an id from the request without scoping the query to the current user, tenant or role (insecure direct object reference) is CRITICAL.
3. Compare secrets and signatures with `crypto.timingSafeEqual`, not `===` (WARNING on an auth path, SUGGESTION elsewhere).
4. `enableCors({ origin: true, credentials: true })` or a `*` origin with credentials is WARNING.

### Input validation

1. Every request body, query and param object needs a DTO class with `class-validator` decorators, and the global `ValidationPipe` must keep `whitelist: true`. A body typed as `any`, an entity, or an inline type gets no validation: that is WARNING, and CRITICAL when the value reaches a query, a file path or a shell command.
2. Passing a request body straight into `save`, `update`, `create` or `Object.assign` on an entity lets a caller set any column, such as `role` or `ownerId` (mass assignment). That is CRITICAL.
3. Numeric and UUID route params need `ParseIntPipe` or `ParseUUIDPipe` (WARNING).
4. File uploads need size and type limits on the interceptor (WARNING).

### Data access

1. SQL built with string concatenation or template literals (`query()`, `createQueryBuilder().where(\`...${x}\`)`, `$queryRawUnsafe`, `$executeRawUnsafe`) is CRITICAL; use parameters.
2. Two or more writes that must succeed together without a transaction are WARNING.
3. `synchronize: true` in a TypeORM config that can reach production is CRITICAL. An entity change without a matching migration is WARNING.
4. A query inside a loop over request data (N+1) is WARNING when the list is unbounded.
5. A list endpoint with no `take` or limit is WARNING.

### Secrets and logging

1. Secrets, tokens and connection strings must come from `ConfigService` or the environment, never literals. A committed secret is CRITICAL.
2. Logging a token, password, API key, SAS URL, connection string or a whole request body or headers object is CRITICAL. Logging personal data (email, phone, address) is WARNING.

### Async and error handling

1. An unawaited promise is WARNING, unless it is clearly fire-and-forget with its own `.catch`.
2. A `catch` that swallows an error without logging or rethrowing is WARNING.
3. Throw the matching Nest HTTP exception (`NotFoundException`, `ForbiddenException`, …). Returning an error object with status 200 is WARNING. Sending `error.message` or a stack trace to the client from a non-HTTP exception is WARNING.

### Dependency injection and lifecycle

1. A new provider must be registered in its module or exported from an imported module; a constructor dependency the module cannot resolve fails at startup (CRITICAL).
2. Per-request data (the user, a tenant id, a request object) stored on a field of a default-scoped (singleton) provider is CRITICAL: concurrent requests overwrite each other.
3. Injecting a `Scope.REQUEST` provider makes every consumer request-scoped; adding one to a hot path is SUGGESTION.

## Conventions to respect

Formatting and lint rules are enforced by Prettier and ESLint; do not comment on them. Prefer the patterns already used in the surrounding module over generic style preferences.
