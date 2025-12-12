FROM golang:1.22.3-alpine
ENV repo /go/src/github.com/Orange-Health/oms
WORKDIR ${repo}
RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata \
    ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff wget

# Install Air for hot reload in a cached layer
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install github.com/cosmtrek/air@v1.27.3

# Download dbmate in a separate cached layer with pinned version
ARG TARGETARCH
RUN ARCH=$(echo ${TARGETARCH:-amd64} | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g') && \
    wget -O /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/download/v2.11.0/dbmate-linux-${ARCH} && \
    chmod +x /usr/local/bin/dbmate

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
EXPOSE 8080
CMD ["go", "run", "main.go"]

