# Repository rules — Dockerfiles and Docker Compose

This repository builds container images with Dockerfiles (BuildKit) and runs local or test environments with Docker Compose. Review `Dockerfile*`, `*.dockerfile`, `.dockerignore` and `compose*.yaml` / `docker-compose*.yml` changes according to the rules below.

## Container rules

### Secrets

1. A secret in `ENV`, `ARG`, `LABEL`, a `RUN` command line, or a copied file (`.env`, keys, `.npmrc` / `.pypirc` with tokens, cloud credentials) is CRITICAL: build arguments and layers are readable by anyone who can pull the image. Use `RUN --mount=type=secret`.
2. `COPY . .` (or `ADD .`) when `.dockerignore` does not exclude `.git`, `.env*` and credential files is WARNING.
3. A password or token as a literal in a Compose file is CRITICAL in a file used beyond local development, and WARNING otherwise; use an `.env` file that is not committed, or `secrets:`.

### Supply chain

1. Piping a downloaded script into a shell (`curl … | sh`) is WARNING, and CRITICAL over plain `http://` or with certificate checks turned off.
2. Turning off TLS verification during a build (`curl -k`, `wget --no-check-certificate`, `pip --trusted-host`, `npm config set strict-ssl false`, `GIT_SSL_NO_VERIFY`) is CRITICAL.
3. A base image with the `latest` tag or no tag is WARNING; pin a version, and a digest for production images.
4. `ADD` of a remote URL without `--checksum`, or a downloaded binary without a checksum or signature check, is WARNING.

### Runtime hardening

1. A final stage that runs as root (no `USER` with a non-root user, or `USER root` at the end) is WARNING.
2. `chmod 777`, or `chmod -R` on application or system directories, is WARNING.
3. Installing or running `sshd`, or exposing port 22, in an application image is WARNING.
4. In Compose, `privileged: true`, mounting `/var/run/docker.sock`, or `network_mode: host` is CRITICAL unless the service is clearly a local-only tool that needs it.
5. Publishing a database, cache or admin port on all interfaces (`"5432:5432"` rather than `"127.0.0.1:5432:5432"`) is WARNING.

### Correctness and size

1. `ENTRYPOINT` or `CMD` in shell form for the main process is WARNING: the process does not get `SIGTERM` and shutdown is not graceful. Use the exec (JSON array) form.
2. Build tools, compilers or the full SDK in the final runtime image when a multi-stage build would leave them out is SUGGESTION.
3. `apt-get install` without `--no-install-recommends` and without removing `/var/lib/apt/lists/*` in the same layer, or `apt-get update` in a separate layer from `install`, is SUGGESTION.
4. Copying the whole source before installing dependencies, so every code change reinstalls them, is SUGGESTION.

## Conventions to respect

`hadolint` runs in CI; do not comment on what it already reports. Prefer the base images and stage layout already used in the repository.
