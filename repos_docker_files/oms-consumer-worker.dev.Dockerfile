FROM golang:1.22.3-alpine

ENV repo /go/src/github.com/Orange-Health/oms

WORKDIR ${repo}

RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff

COPY go.mod ${repo}
COPY go.sum ${repo}
RUN --mount=type=cache,target=/go/pkg/mod go mod download

ADD . ${repo}

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -o /go/bin/consumer ${repo}/main/consumer

ENV QUEUE_NAME=all

# No entrypoint, container directly starts the Go binary
CMD ["/go/bin/consumer"]
