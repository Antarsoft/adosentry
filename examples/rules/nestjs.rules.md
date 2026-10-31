# Repository rules — NestJS API

This repository is a NestJS API in TypeScript. Review TypeScript changes according to the rules below.

## NestJS rules

### Security

1. Secrets, tokens and connection strings must come from configuration, never literals. A committed secret is CRITICAL.
2. Logging a token, password, API key, SAS URL or connection string is CRITICAL. Logging personal data (email, phone, address) is WARNING.
3. A new controller route without the guard its siblings use (auth, API key, roles) is CRITICAL unless it is clearly meant to be public.
4. Compare secrets with a constant-time comparison, not `===` (SUGGESTION unless on an auth path, then WARNING).

### Input validation

1. Every DTO used for a request body needs `class-validator` decorators, and the route needs the global or local `ValidationPipe`. A body that reaches a query or a file path unvalidated is CRITICAL.
2. File uploads need size and type limits on the interceptor (WARNING).

### Async and error handling

1. Every unawaited promise is a bug risk (WARNING).
2. Do not swallow errors in `catch` blocks without logging or rethrowing (WARNING).
3. Throw Nest HTTP exceptions with the right status; do not return error objects with status 200 (WARNING).

### Dependency injection

1. A new provider must be registered in its module; a constructor change that adds a dependency the module does not provide fails at startup (CRITICAL).

## Conventions to respect

Formatting is enforced by Prettier and ESLint; do not comment on it.
