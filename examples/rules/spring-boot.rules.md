# Repository rules — Spring Boot service (Java)

This repository is a Spring Boot 3 service in Java 17+, with Spring Web MVC, Spring Security, Spring Data JPA (Hibernate) and `application*.yml` configuration. Review `.java`, `.kt`, `application*.yml`/`.properties` and migration changes according to the rules below.

## Spring Boot rules

### Authentication and authorisation

1. A new endpoint without the method security (`@PreAuthorize`, `@Secured`) or `SecurityFilterChain` rule its siblings rely on is CRITICAL unless it is clearly meant to be public. Adding `permitAll()` to a path that serves user data is CRITICAL.
2. Loading, changing or deleting an entity by an id from the request without scoping it to the current user or tenant is CRITICAL (insecure direct object reference).
3. Turning off CSRF protection for an app that uses session cookies is WARNING. CORS with `allowedOrigins("*")` or `allowedOriginPatterns("*")` plus `allowCredentials(true)` is WARNING.

### Injection and untrusted input

1. JPQL, HQL or native SQL built with `+`, `String.format` or `concat` (`createQuery`, `createNativeQuery`, `@Query` with SpEL on raw input, `JdbcTemplate`) is CRITICAL; use bound parameters.
2. Binding a JPA `@Entity` directly from `@RequestBody` and saving it is CRITICAL (mass assignment): a caller can set any column. Bind a request record and map the allowed fields.
3. `ObjectInputStream.readObject`, Jackson default typing, or XStream on data from outside is CRITICAL.
4. A `DocumentBuilderFactory`, `SAXParserFactory` or `XMLInputFactory` for external XML without disabling DTDs and external entities is CRITICAL (XXE).
5. A request value in a SpEL expression, `Runtime.exec` / `ProcessBuilder`, a file path, or an outgoing URL without validation or an allow-list is CRITICAL.
6. A request body without `@Valid` and Bean Validation constraints before use is WARNING.

### Configuration, secrets and logging

1. A password, token, key or connection string with credentials in `application*.yml`/`.properties` or source is CRITICAL; use environment variables or a secret store.
2. `management.endpoints.web.exposure.include: "*"` (or exposing `env`, `heapdump`, `configprops`, `threaddump`) without restricting access is CRITICAL.
3. `server.error.include-stacktrace: always`, `include-message: always`, or `spring.jpa.hibernate.ddl-auto: update|create|create-drop` in configuration that can reach production is WARNING.
4. Logging a password, token, `Authorization` header or a whole request or entity holding personal data is CRITICAL.

### Transactions and persistence

1. `@Transactional` on a `private` method, or called from another method of the same bean (self-invocation), has no effect (WARNING).
2. Two or more writes that must succeed together outside a transaction are WARNING. Writes inside `@Transactional(readOnly = true)` are WARNING.
3. Touching a lazy association outside a transaction (with `open-in-view` off) is WARNING: `LazyInitializationException`.
4. Navigating a lazy association inside a loop (N+1) is WARNING when the list is unbounded. `findAll()` without a `Pageable` on a growing table is WARNING.
5. A schema change in an entity without a Flyway or Liquibase migration is WARNING. A migration that drops or renames a column or table with data, without a data-preserving step, is CRITICAL.

### Concurrency and resources

1. A mutable instance field on a singleton bean (`@Service`, `@Component`, `@RestController`) that holds per-request data is CRITICAL: requests overwrite each other.
2. A shared static `SimpleDateFormat` or other non-thread-safe object is WARNING.
3. A stream, reader, connection or client not closed with try-with-resources is WARNING.
4. `RestTemplate`, `RestClient` or `WebClient` calls to other services without connect and read timeouts are WARNING.

### Errors and null safety

1. A `catch` that swallows an exception without logging or rethrowing is WARNING. Returning an error body with status 200 is WARNING.
2. `Optional.get()` without a presence check, or comparing boxed numbers with `==`, is WARNING.

## Conventions to respect

Formatting and static analysis are enforced by Spotless (or Checkstyle) and the compiler; do not comment on them. Prefer the patterns already used in the surrounding module (records for DTOs, constructor injection, service layer) over generic preferences.
