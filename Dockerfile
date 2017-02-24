FROM alpine:3.4

RUN apk add --no-cache docker git bash

COPY builder /builder

ENTRYPOINT "/builder"

