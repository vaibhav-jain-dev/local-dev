FROM golang:1.22.3-alpine
ENV repo /go/src/github.com/Orange-Health/oms
WORKDIR ${repo}
RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata \
    ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff
RUN go install github.com/cosmtrek/air@v1.27.3
ADD https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 /usr/local/bin/dbmate
RUN chmod +x /usr/local/bin/dbmate
COPY go.mod go.sum ./
RUN go mod download
COPY . .
EXPOSE 8080
CMD ["go", "run", "main.go"]

