# Repository rules — SQL database migrations (PostgreSQL)

This repository holds versioned SQL migrations for a PostgreSQL 14+ database (Flyway, Liquibase SQL, golang-migrate, or plain numbered `.sql` files). The application is deployed with rolling updates, so the old and new versions of the code run against the same schema for a while. Review `.sql` migration changes according to the rules below.

## Migration rules

### Data loss

1. `DROP TABLE`, `DROP COLUMN`, `TRUNCATE` or `DROP SCHEMA` on data that is still read, or without a preceding step that copies or archives the data, is CRITICAL.
2. `UPDATE` or `DELETE` without a `WHERE` clause (or with one that matches every row by mistake) is CRITICAL.
3. Changing a column to a narrower type (shorter `varchar(n)`, `integer` from `bigint`, lower `numeric` precision) or a type that cannot hold every existing value is CRITICAL.
4. Editing, renaming or deleting a migration that has already been applied (an earlier version number) is WARNING: checksums fail and environments drift. Add a new migration instead.

### Zero-downtime compatibility

1. Renaming a column or table, or dropping one the current code still uses, in the same release as the code change is WARNING. Use expand and contract: add the new one, write to both, backfill, switch reads, then drop.
2. Adding a `NOT NULL` column without a default, or adding a default that is not a constant (`now()` is fine on PostgreSQL 11+, a function per row is not), is WARNING.

### Locking on large tables

1. `CREATE INDEX` without `CONCURRENTLY` on an existing table that may be large is WARNING: it blocks writes for the whole build. `CREATE INDEX CONCURRENTLY` inside a transaction block fails (WARNING).
2. Adding a `FOREIGN KEY` or `CHECK` constraint without `NOT VALID` and a later `VALIDATE CONSTRAINT` is WARNING.
3. `ALTER COLUMN … TYPE` that rewrites the table, or `SET NOT NULL` without a validated `CHECK (col IS NOT NULL)` first, on a large table is WARNING.
4. A backfill that updates every row of a large table in one statement or transaction is WARNING; batch it.
5. A migration without `SET lock_timeout` that takes an `ACCESS EXCLUSIVE` lock on a busy table is SUGGESTION.

### Security

1. `GRANT ALL`, grants to `PUBLIC`, or a new role with `SUPERUSER`, `CREATEROLE` or `BYPASSRLS` is CRITICAL.
2. A password or secret in a migration (`CREATE ROLE … PASSWORD '…'`) is CRITICAL.
3. Disabling row-level security, or dropping a policy, on a table that has it is CRITICAL.

### Schema design

1. Money stored as `real`, `double precision` or `float` is WARNING; use `numeric` or integer minor units.
2. A foreign key column without an index is SUGGESTION.
3. `timestamp` without time zone for an instant in time is SUGGESTION; use `timestamptz`.

## Conventions to respect

Formatting is not reviewed. Follow the naming, versioning and idempotency conventions (`IF NOT EXISTS`, one change per file) already used in the migrations folder.
