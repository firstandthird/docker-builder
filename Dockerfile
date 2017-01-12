FROM alpine:3.5

RUN apk add --no-cache docker git bash

COPY builder /builder

ENTRYPOINT "/builder"

