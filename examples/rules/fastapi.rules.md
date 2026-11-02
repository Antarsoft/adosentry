# Repository rules — FastAPI service

This repository is a FastAPI service in Python 3.11+, with Pydantic v2 models, SQLAlchemy 2 (async sessions) and dependency injection through `Depends`. Review `.py` changes and Alembic migrations according to the rules below.

## FastAPI rules

### Authentication and authorisation

1. A new route or router without the auth dependency its siblings use (`Depends(get_current_user)`, a `dependencies=[…]` list, `Security(…)`) is CRITICAL unless it is clearly meant to be public.
2. Loading, changing or deleting a row by an id from the request without filtering to the current user or tenant is CRITICAL (insecure direct object reference).
3. Decoding a JWT without verifying its signature, without an `algorithms` list, or without checking expiry is CRITICAL.
4. `CORSMiddleware` with `allow_origins=["*"]` and `allow_credentials=True` is WARNING.

### Injection and data exposure

1. SQL built with f-strings, `%` or `+` inside `text()`, `exec_driver_sql` or a raw cursor is CRITICAL; use bound parameters.
2. Creating or updating a model from the whole request body (`Model(**body.model_dump())`, `setattr` in a loop over the payload) when the schema can carry fields such as `role`, `is_admin` or `owner_id` is CRITICAL (mass assignment). Use a request schema with only the allowed fields.
3. A route that returns an ORM object without a `response_model` (or return type) that excludes secrets is CRITICAL when the object has fields such as `hashed_password`, tokens or keys.
4. A request value in a file path, a shell command, `eval`, `pickle.loads` or `yaml.load` without `SafeLoader` is CRITICAL.
5. Fetching a URL taken from the request without a host allow-list is CRITICAL (SSRF).

### Async correctness

1. Blocking calls inside `async def` (the `requests` library, `time.sleep`, a synchronous database driver or ORM session, large synchronous file I/O, CPU-heavy work) block the event loop for every request (WARNING). Use an async client, `await asyncio.sleep`, or a plain `def` route / `run_in_threadpool`.
2. Calling a coroutine without `await` is WARNING: it never runs.
3. Creating an engine, client or connection pool per request is WARNING; create it once at startup (lifespan).
4. A session or connection dependency that does not close in a `yield` dependency's `finally` is WARNING. Using a request-scoped session inside `BackgroundTasks` after the response is WARNING.

### Validation and models

1. A mutable default argument (`= []`, `= {}`) in a function or a Pydantic field without `Field(default_factory=…)` is WARNING.
2. Pydantic v1 APIs (`.dict()`, `.parse_obj()`, `@validator`, `class Config`) in a v2 codebase are SUGGESTION.
3. Unbounded strings or lists in a request model that reach storage or a loop are SUGGESTION; add `max_length`.

### Secrets, logging and errors

1. A secret, token or connection string in source is CRITICAL; use settings loaded from the environment.
2. Logging a password, token, `Authorization` header or a whole request body is CRITICAL.
3. `HTTPException(detail=str(exc))` for an unexpected exception, or returning a stack trace, is WARNING.
4. A bare `except:` or `except Exception: pass` that swallows errors is WARNING.

### Migrations

1. A model change without an Alembic migration is WARNING. A migration that drops or renames a column or table with data, without a data-preserving step, is CRITICAL.

## Conventions to respect

Formatting, imports and lint are enforced by Ruff and types by mypy or pyright; do not comment on them. Prefer the patterns already used in the surrounding routers and services over generic preferences.
