#!/usr/bin/env bash
set -e

OPTIONS=/data/options.json
PIDS=()

term_handler() {
  trap - TERM INT
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 0
}
trap term_handler TERM INT

/generate-nginx-conf.sh

HA_ENABLED=$(jq -r '.ha.enabled' "$OPTIONS")
if [ "$HA_ENABLED" = "true" ]; then
  /generate-keepalived-conf.sh
  keepalived -n -l -D --vrrp -f /etc/keepalived/keepalived.conf &
  PIDS+=("$!")
fi

# The Let's Encrypt add-on renews the certificates without restarting this
# add-on, and nginx does not re-read the files by itself: reload it when they
# change.
cert_watch() {
  local last_hash=""
  while true; do
    sleep 3600
    local hash
    hash=$(find /ssl -maxdepth 1 -type f -name '*.pem' 2>/dev/null | sort | xargs -r md5sum | md5sum)
    if [ -n "$last_hash" ] && [ "$hash" != "$last_hash" ]; then
      echo "Certificati aggiornati, ricarico nginx..."
      /generate-nginx-conf.sh && nginx -s reload || echo "reload nginx fallito" >&2
    fi
    last_hash="$hash"
  done
}
cert_watch &
PIDS+=("$!")

nginx -g "daemon off;" &
PIDS+=("$!")

wait -n
term_handler
