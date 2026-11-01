# syntax=docker/dockerfile:1
# Metrics API image: static Go binary on distroless, running as a non-root user.
# Base images are pinned by digest so builds are reproducible; Dependabot keeps the pins current.

FROM golang:1.25-alpine@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS build
WORKDIR /src

# Dependencies first so this layer is cached until go.mod or go.sum change.
# go.sum is the source of truth: no "go mod tidy" here, and the download is verified.
COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY *.go ./
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/ai-metrics-api .

# distroless/static ships CA certificates and tzdata, with no shell or package manager.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/ai-metrics-api /ai-metrics-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/ai-metrics-api"]
