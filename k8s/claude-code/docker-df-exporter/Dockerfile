FROM alpine:3.20
# dockerd's Engine API responses use chunked transfer-encoding; curl
# de-chunks correctly, not worth reimplementing HTTP framing by hand for a
# poll loop this small.
RUN apk add --no-cache curl jq
COPY export.sh /export.sh
RUN chmod +x /export.sh
ENTRYPOINT ["/export.sh"]
