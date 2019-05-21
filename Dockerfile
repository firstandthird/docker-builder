FROM alpine:3.9

RUN apk add --no-cache docker git bash curl py-pip gcc python-dev musl-dev libffi-dev openssl-dev make

RUN pip install docker-compose

COPY builder /builder

ENTRYPOINT "/builder"

