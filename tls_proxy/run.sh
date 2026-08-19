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

  # A *fast* shutdown, deliberately not a graceful one. `nginx -s quit` waits
  # for every request in flight to finish, and a request stuck on an
  # unreachable backend keeps it waiting for as long as that request's timeouts
  # allow - so with one dead backend being retried by its clients, the quit
  # never completes. The Supervisor gives the container ten seconds before
  # SIGKILL, and being killed is what gets reported as a crash. `nginx -s stop`
  # terminates the workers at once; a request cut here was about to be cut by
  # the stop in any case.
  if [ -s /var/run/nginx.pid ]; then
    nginx -s stop 2>/dev/null || true
  fi

  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done

  # Three seconds is generous for processes that have already been told to go,
  # and leaves the rest of the ten second window as margin.
  local waited=0 pid alive
  while [ "${waited}" -lt 3 ]; do
    alive=""
    for pid in "${PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive="yes"
    done
    [ -n "${alive}" ] || break
    sleep 1
    waited=$((waited + 1))
  done

  # Whatever is left is not leaving on its own, and waiting for it only turns
  # a clean stop into a killed container.
  for pid in "${PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
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
