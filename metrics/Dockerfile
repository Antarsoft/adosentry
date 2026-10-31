FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -o /out/ai-metrics-api .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/ai-metrics-api /usr/local/bin/ai-metrics-api
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ai-metrics-api"]
