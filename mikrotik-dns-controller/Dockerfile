FROM golang:1.21-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix crunchy -o mikrotik-dns-controller .

# Final stage
FROM alpine:latest

# Install ca-certificates for HTTPS
RUN apk --no-cache add ca-certificates

WORKDIR /app

# Copy binary from builder and set executable permission
COPY --from=builder --chown=1000:1000 /app/mikrotik-dns-controller .
RUN chmod +x /app/mikrotik-dns-controller

# Create non-root user
RUN addgroup -g 1000 controller && \
    adduser -D -u 1000 -G controller controller

USER controller

ENTRYPOINT ["/app/mikrotik-dns-controller"]
