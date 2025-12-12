FROM golang:1.22.3-alpine

ENV repo /go/src/github.com/Orange-Health/oms

WORKDIR ${repo}

RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff

# Install Air for hot reload
RUN go install github.com/cosmtrek/air@v1.27.3

COPY go.mod ${repo}
COPY go.sum ${repo}
RUN --mount=type=cache,target=/go/pkg/mod go mod download

ADD . ${repo}

ENV QUEUE_NAME=all

# Run with Air for hot reload instead of pre-compiled binary
# Air will watch for file changes and automatically rebuild/restart the scheduler
# Air runs with default settings (no config file needed)
CMD ["air"]
