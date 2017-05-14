FROM alpine:3.4

RUN apk add --no-cache docker git bash curl py-pip

RUN pip install docker-compose

COPY builder /builder

ENTRYPOINT "/builder"

