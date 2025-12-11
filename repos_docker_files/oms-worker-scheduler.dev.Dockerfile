FROM golang:1.22.3-alpine

ENV repo /go/src/github.com/Orange-Health/oms

WORKDIR ${repo}

RUN apk add --no-cache build-base imagemagick-dev imagemagick tzdata ca-certificates aws-cli imagemagick-jpeg imagemagick-tiff

COPY go.mod ${repo}
COPY go.sum ${repo}
RUN go mod download

ADD . ${repo}

RUN go build -o /go/bin/scheduler ${repo}/main/scheduler

RUN chmod +x ./docker-entrypoint.sh

ENV QUEUE_NAME=all

ENTRYPOINT [ "./docker-entrypoint.sh" ]

CMD [ "/go/bin/scheduler" ]
