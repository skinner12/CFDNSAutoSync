FROM alpine:3.20

RUN apk add --no-cache bash curl jq bc

COPY cloudflare_dns_updater.sh /usr/local/bin/cloudflare_dns_updater.sh
RUN chmod +x /usr/local/bin/cloudflare_dns_updater.sh

WORKDIR /app

ENV CHECK_INTERVAL=300

CMD while true; do \
      /usr/local/bin/cloudflare_dns_updater.sh --config /app/domain.json --log-file /app/logs/dns_updater.log; \
      sleep "${CHECK_INTERVAL}"; \
    done
