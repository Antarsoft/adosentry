# Repository rules — Django app

This repository is a Django 4.2+ project in Python 3.11+, with the Django ORM, Django REST Framework for the API, and Celery for background tasks. Review `.py` changes, templates and migrations according to the rules below.

## Django rules

### Authentication and authorisation

1. A new view, viewset or action without the `permission_classes`, `@login_required` or mixin its siblings use is CRITICAL unless it is clearly meant to be public.
2. Looking up an object by an id from the request (`get_object_or_404(Model, pk=pk)`, `Model.objects.get(id=…)`, a viewset `queryset` of all rows) without filtering to the current user, team or tenant is CRITICAL (insecure direct object reference).
3. `@csrf_exempt` on a view that uses session authentication is WARNING.
4. `redirect()` to a `next` or other URL from the request without `url_has_allowed_host_and_scheme` is CRITICAL (open redirect).

### Injection and untrusted input

1. SQL built with f-strings, `%` or `+` in `cursor.execute`, `.raw()`, `.extra()` or `RawSQL` is CRITICAL; pass parameters separately.
2. `mark_safe`, `format_html` with pre-formatted input, `|safe` or `{% autoescape off %}` on user data is CRITICAL.
3. `pickle`, `yaml.load` without `SafeLoader`, `eval` or `exec` on data from outside is CRITICAL.
4. A writable DRF serializer with `fields = '__all__'`, or one that exposes fields such as `is_staff`, `owner` or `role` as writable, is CRITICAL (mass assignment).
5. A request value in a file path without checking it stays under the intended root is CRITICAL.

### Settings and secrets

1. A literal `SECRET_KEY`, password, token or key in settings or source is CRITICAL; read it from the environment.
2. `DEBUG = True`, `ALLOWED_HOSTS = ['*']`, or turning off `SECURE_*` / `SESSION_COOKIE_SECURE` / `CSRF_COOKIE_SECURE` in production settings is WARNING.
3. Logging a password, token, or whole `request.headers`, `request.POST` or `request.body` is CRITICAL.

### ORM and data integrity

1. Accessing a related object or a reverse relation inside a loop or a serializer method without `select_related` / `prefetch_related` is WARNING when the list is unbounded (N+1).
2. Two or more writes that must succeed together outside `transaction.atomic()` are WARNING.
3. Read-modify-write on a counter or balance (`obj.x += 1; obj.save()`) without `F()` expressions or `select_for_update()` is WARNING: concurrent requests lose updates.
4. `.get()` without handling `DoesNotExist` (outside `get_object_or_404`) is WARNING.
5. A list endpoint without pagination is WARNING.
6. Queuing a Celery task that reads rows written in the same transaction, without `transaction.on_commit`, is WARNING: the task can run before the commit.

### Migrations

1. A model change without a matching migration is WARNING.
2. A migration that drops or renames a column or table with data, without a data-preserving step, is CRITICAL.
3. Adding a non-nullable column without a default to a large table, or an index without `AddIndexConcurrently` on PostgreSQL, is WARNING (locks the table).
4. A data migration that imports models directly instead of using `apps.get_model` is WARNING. `RunPython` without a reverse function is SUGGESTION.

### Errors

1. A bare `except:` or `except Exception: pass` that swallows errors is WARNING.

## Conventions to respect

Formatting, imports and lint are enforced by Ruff (or Black and isort) and types by mypy; do not comment on them. Prefer the patterns already used in the surrounding app (function or class-based views, serializers, services) over generic preferences.
