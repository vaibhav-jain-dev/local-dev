FROM golang:1.22.3-alpine
ENV repo /go/src/github.com/Orange-Health/oms
WORKDIR ${repo}
RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata \
    ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff

# Install Air for hot reload and Delve for debugging
RUN go install github.com/cosmtrek/air@v1.27.3
RUN go install github.com/go-delve/delve/cmd/dlv@latest

ADD https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 /usr/local/bin/dbmate
RUN chmod +x /usr/local/bin/dbmate
COPY go.mod go.sum ./
RUN go mod download
COPY . .

# Expose application port and debug port
EXPOSE 8080 2345

# Run with go run (use Air for hot reload if needed)
# To debug, attach debugger to port 2345
CMD ["go", "run", "main.go"]

