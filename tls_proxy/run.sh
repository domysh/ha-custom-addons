#!/usr/bin/env bash
set -e

OPTIONS=/data/options.json
PIDS=()

# The Supervisor stops the add-on by sending SIGTERM to this script, which is
# PID 1 here. Without a handler that ends in `exit 0`, the shell dies of the
# signal, the container reports exit code 143 and Home Assistant logs the stop
# as a failure.
term_handler() {
  trap - TERM INT

  # nginx first, and by asking rather than killing: `quit` is its graceful
  # shutdown, which finishes the requests in flight instead of cutting them.
  if [ -s /var/run/nginx.pid ]; then
    nginx -s quit 2>/dev/null || true
    for _ in $(seq 1 10); do
      [ -s /var/run/nginx.pid ] || break
      sleep 1
    done
  fi

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
      echo "Certificates changed, reloading nginx..."
      /generate-nginx-conf.sh && nginx -s reload || echo "nginx reload failed" >&2
    fi
    last_hash="$hash"
  done
}
cert_watch &
PIDS+=("$!")

nginx -g "daemon off;" &
PIDS+=("$!")

# `|| true` because the exit status here is the dead child's, and with `set -e`
# a backend process that exits non-zero would end this script on that status -
# reported by the Supervisor as a crash - instead of running the orderly
# shutdown below.
wait -n || true
term_handler
