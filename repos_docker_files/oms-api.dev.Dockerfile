FROM golang:1.22.3-alpine
ENV repo /go/src/github.com/Orange-Health/oms
WORKDIR ${repo}
RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata \
    ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff
RUN go install github.com/cosmtrek/air@v1.27.3
ARG TARGETARCH
RUN ARCH=$(echo ${TARGETARCH:-$(uname -m)} | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g') && \
    wget -O /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-${ARCH} && \
    chmod +x /usr/local/bin/dbmate
COPY go.mod go.sum ./
RUN go mod download
COPY . .
EXPOSE 8080
# Run with Air for hot reload
# Air will watch for file changes and automatically rebuild/restart the app
CMD ["air", "-c", ".air.toml"]

