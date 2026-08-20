FROM alpine:3.20
# dockerd's Engine API responses use chunked transfer-encoding; curl
# de-chunks correctly, not worth reimplementing HTTP framing by hand for a
# poll loop this small.
RUN apk add --no-cache curl jq
COPY export.sh /export.sh
COPY image-gc.sh /image-gc.sh
RUN chmod +x /export.sh /image-gc.sh
ENTRYPOINT ["/export.sh"]
