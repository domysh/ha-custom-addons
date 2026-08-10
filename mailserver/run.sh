#!/usr/bin/env bash
set -e

# Home Assistant only guarantees persistence for the add-on's own /data folder.
# docker-mailserver instead expects its state under /var/mail, /var/mail-state,
# /var/log/mail and /tmp/docker-mailserver, so those are relocated under /data
# and symlinked back into place. This also transparently migrates any content
# already sitting at those paths (e.g. from an older, non-persistent build).
declare -A DIRS=(
  [mail]=/var/mail
  [mail-state]=/var/mail-state
  [log]=/var/log/mail
  [config]=/tmp/docker-mailserver
)

for name in "${!DIRS[@]}"; do
  target="${DIRS[$name]}"
  store="/data/${name}"
  mkdir -p "$store"
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    cp -a "${target}/." "$store/" 2>/dev/null || true
    rm -rf "$target"
  fi
  ln -sfn "$store" "$target"
done

exec /usr/bin/dumb-init -- supervisord -c /etc/supervisor/supervisord.conf
