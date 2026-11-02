# Repository rules — ASP.NET Core API (C#)

This repository is an ASP.NET Core 8+ web API in C# 12+ with nullable reference types enabled, using controllers or minimal APIs, Entity Framework Core and the built-in dependency injection container. Review `.cs`, `.csproj` and `appsettings*.json` changes according to the rules below.

## ASP.NET Core rules

### Authentication and authorisation

1. A new controller, action or minimal API endpoint without the `[Authorize]` attribute, policy or `RequireAuthorization()` its siblings use is CRITICAL unless it is clearly meant to be public. Adding `[AllowAnonymous]` to an endpoint that reads or changes user data is CRITICAL.
2. Loading, changing or deleting a record by an id from the request without scoping the query to the current user or tenant is CRITICAL (insecure direct object reference).
3. JWT bearer options that turn off `ValidateIssuer`, `ValidateAudience`, `ValidateLifetime` or `ValidateIssuerSigningKey` are CRITICAL.
4. Turning off antiforgery validation on an endpoint that uses cookie authentication is WARNING.
5. `AllowAnyOrigin()` on an API that uses cookies or returns user data is WARNING.

### Injection and untrusted input

1. `FromSqlRaw`, `ExecuteSqlRaw` or `SqlCommand` text built with string interpolation or concatenation is CRITICAL. Use `FromSql` / `FromSqlInterpolated` or parameters.
2. Binding an EF Core entity directly from the request body and saving it is CRITICAL (over-posting): a caller can set any column, such as `Role` or `OwnerId`. Bind a request DTO and map the allowed fields.
3. A request value in `Path.Combine`, `File.*` or `PhysicalFile` without checking the resolved path stays under the intended root is CRITICAL.
4. A request value in `Process.Start` arguments, or `Html.Raw` / `MarkupString` with user data, is CRITICAL.
5. `BinaryFormatter`, or Json.NET with `TypeNameHandling` other than `None`, on data from outside is CRITICAL.
6. A request DTO without validation (data annotations, FluentValidation) before its values are used is WARNING.

### Secrets and logging

1. A secret, connection string with a password, or key in source or a committed `appsettings*.json` is CRITICAL; use user secrets, environment variables or Key Vault.
2. Logging a password, token, key, connection string or a whole request object is CRITICAL. Logging personal data is WARNING.
3. Returning exception messages or stack traces to the client outside the Development environment is WARNING.

### Async

1. `.Result`, `.Wait()` or `.GetAwaiter().GetResult()` on a task in request-handling code is WARNING: it blocks a thread-pool thread and can deadlock or starve the server.
2. `async void` outside an event handler is WARNING: exceptions crash the process.
3. A task that is neither awaited nor observed is WARNING.
4. Not passing the request's `CancellationToken` to EF Core or `HttpClient` calls on a long-running endpoint is SUGGESTION.

### Dependency injection and resources

1. A singleton (or a static field) that holds a `DbContext` or another scoped service is CRITICAL: `DbContext` is not thread-safe and the instance is shared by every request. Use `IServiceScopeFactory` or `IDbContextFactory`.
2. `new HttpClient()` per call is WARNING (socket exhaustion); use `IHttpClientFactory` or a typed client.
3. An `IDisposable` created in a method without `using` or disposal is WARNING.

### Entity Framework Core

1. Calling `ToList()`, `AsEnumerable()` or `ToArray()` before `Where`, `OrderBy` or paging loads the whole table into memory (WARNING).
2. A query inside a loop (N+1), including lazy-loaded navigation access in a loop, is WARNING when the list is unbounded.
3. A migration that drops or renames a column or table holding data, without a data-preserving step, is CRITICAL.
4. A list endpoint without paging or `Take` is WARNING.

### Nullability and exceptions

1. The null-forgiving operator `!` on a value that comes from the request, configuration or the database is WARNING.
2. A `catch (Exception)` that swallows the error without logging or rethrowing is WARNING. `throw ex;` (which resets the stack trace) is SUGGESTION; use `throw;`.

## Conventions to respect

Formatting and analyser rules are enforced by `dotnet format`, `.editorconfig` and the compiler's nullable warnings; do not comment on them. Prefer the patterns already used in the surrounding project (controllers or minimal APIs, MediatR or services) over generic preferences.
