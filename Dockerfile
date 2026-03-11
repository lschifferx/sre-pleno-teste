# =============================================================================
# Stage 1 — Builder
# =============================================================================
FROM golang:1.22-alpine AS builder

# Install security patches + build deps
RUN apk update && apk add --no-cache \
    ca-certificates \
    git \
    tzdata \
    && rm -rf /var/cache/apk/*

WORKDIR /build

# Cache dependency downloads before copying source
COPY app/go.mod app/go.sum ./
RUN go mod download && go mod verify

# Copy source and build a statically-linked binary
COPY app/ .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -ldflags="-w -s -extldflags '-static'" \
    -trimpath \
    -o /build/server \
    ./cmd/server

# =============================================================================
# Stage 2 — Runtime (distroless / minimal attack surface)
# =============================================================================
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

# Bring timezone data and CA certs from builder
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy compiled binary
COPY --from=builder /build/server /server

# Runtime configuration
ENV APP_ENV=staging
ARG PORT=8080
ENV PORT=${PORT}

# Expose application port
EXPOSE ${PORT}

# Run as non-root (UID 65532 = nonroot in distroless)
USER nonroot:nonroot

ENTRYPOINT ["/server"]
