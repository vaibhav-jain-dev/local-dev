FROM golang:1.22.3-alpine
ENV repo /go/src/github.com/Orange-Health/oms
WORKDIR ${repo}
RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata \
    ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff wget

# Install Air for hot reload and Delve for debugging (cached layer)
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install github.com/cosmtrek/air@v1.27.3 && \
    go install github.com/go-delve/delve/cmd/dlv@latest

# Download dbmate in a separate cached layer
ARG TARGETARCH
RUN ARCH=$(echo ${TARGETARCH:-amd64} | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g') && \
    wget -O /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/download/v2.11.0/dbmate-linux-${ARCH} && \
    chmod +x /usr/local/bin/dbmate

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .

# Expose application port and debug port
EXPOSE 8080 2345

# Run with go run (use Air for hot reload if needed)
# To debug, attach debugger to port 2345
CMD ["go", "run", "main.go"]

