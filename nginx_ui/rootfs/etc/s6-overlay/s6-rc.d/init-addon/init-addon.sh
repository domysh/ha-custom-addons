#!/usr/bin/env bash
# Everything this add-on does before nginx and nginx-ui start:
#
#   1. point /etc/nginx and /etc/nginx-ui at /data, which is the only directory
#      the Supervisor keeps across a restart, an update or a rebuild,
#   2. turn the handful of add-on options into the environment variables
#      Nginx UI reads, and
#   3. write keepalived's configuration when high availability is on.
#
# It runs as a s6-rc oneshot that init-config, nginx-ui and keepalived depend
# on, so all three see the result - and a failure here would stop all three
# from starting. That is why no option can fail it: a certificate that cannot
# be read falls back to plain HTTP, a keepalived setting that cannot be used
# leaves the virtual IP down, and both say so in the log. The panel stays up,
# because the panel is where those mistakes get corrected.
set -euo pipefail

# Paths, overridable only so the script can be exercised outside a container;
# nothing sets these in the add-on. ENV_DIR is s6-overlay's own copy of the
# container environment: a file written there is an environment variable for
# every service started afterwards, because their run scripts begin with
# `#!/command/with-contenv`.
: "${OPTIONS:=/data/options.json}"
: "${ENV_DIR:=/run/s6/container_environment}"
: "${ETC_NGINX:=/etc/nginx}"
: "${ETC_NGINX_UI:=/etc/nginx-ui}"
: "${DATA_DIR:=/data}"
: "${SSL_DIR:=/ssl}"
: "${KEEPALIVED_CONF:=/etc/keepalived/keepalived.conf}"
: "${GENERATE_KEEPALIVED_CONF:=/usr/local/bin/generate-keepalived-conf.sh}"

log() { echo "[init-addon] $*"; }

setenv() {
  printf '%s' "$2" > "${ENV_DIR}/$1"
}

opt() {
  jq -r "$1" "$OPTIONS"
}

# --- Persistence -------------------------------------------------------------
# Nginx UI keeps its database, its app.ini and every site, stream, certificate
# and template it manages in these two directories. In the upstream image they
# are ordinary directories inside the container, which for an add-on means they
# would be thrown away by the next update - so they become symlinks into /data
# before anything reads them.
#
# The image's own init-config oneshot seeds /etc/nginx from the template in
# /usr/local/etc/nginx when it finds it empty, which is exactly what happens on
# the first start here: /data/nginx is new and empty, so it is populated with
# upstream's nginx.conf, conf.d/nginx-ui.conf and the sites-*/streams-*
# directories the panel expects. On later starts it is already populated and
# left alone, apart from upstream's own hash-checked refresh of the files it
# owns.
persist() {
  local link="$1" store="$2"

  mkdir -p "$store"
  # On the very first start the path exists as a real directory from the image;
  # on a restart of the same container it is already our symlink, and removing
  # a symlink does not touch what it points at.
  [ -L "$link" ] || rm -rf "$link"
  ln -sfn "$store" "$link"
}

persist "$ETC_NGINX"    "${DATA_DIR}/nginx"
persist "$ETC_NGINX_UI" "${DATA_DIR}/nginx-ui"

# --- The panel ---------------------------------------------------------------
# Nginx UI reads app.ini and then lets NGINX_UI_<SECTION>_<KEY> override it, so
# these win over whatever is saved in /data/nginx-ui/app.ini. That is the point:
# the address the panel listens on is the one thing that cannot be fixed from
# inside the panel if it is set wrong, so the add-on options stay authoritative
# and the fields are shown as read-only in the UI.
ADMIN_PORT=$(opt '.admin_port')
ADMIN_HOST=$(opt '.admin_host')
setenv NGINX_UI_SERVER_HOST "$ADMIN_HOST"
setenv NGINX_UI_SERVER_PORT "$ADMIN_PORT"
# Upstream's default is "debug", which logs every request. The panel's own log
# viewer is a better place to look than the add-on log.
setenv NGINX_UI_SERVER_RUN_MODE "release"

# Written in both directions rather than only when on: an environment file
# left over from a previous start with `ssl: true` would otherwise still be
# read as the answer.
setenv NGINX_UI_SERVER_ENABLE_HTTPS "false"
if [ "$(opt '.ssl')" = "true" ]; then
  CERT="${SSL_DIR}/$(opt '.certfile')"
  KEY="${SSL_DIR}/$(opt '.keyfile')"
  if [ ! -r "$CERT" ] || [ ! -r "$KEY" ]; then
    # Serving the panel unencrypted when TLS was asked for would be the wrong
    # kind of helpful, and refusing to start would take the panel - the only
    # place this can be corrected from - down with it. So: plain HTTP, loudly.
    log "ssl is on but ${CERT} or ${KEY} cannot be read; serving the panel over HTTP"
  else
    setenv NGINX_UI_SERVER_ENABLE_HTTPS "true"
    setenv NGINX_UI_SERVER_SSL_CERT "$CERT"
    setenv NGINX_UI_SERVER_SSL_KEY "$KEY"
  fi
fi

# The upstream image assumes /var/run/docker.sock is mounted: it is how it
# replaces its own container during an over-the-air upgrade, and its self-check
# reports the missing socket as a fault. This add-on deliberately does not have
# the socket - it is updated by Home Assistant, from a pinned image tag - and
# this variable is upstream's documented way to say so.
setenv NGINX_UI_IGNORE_DOCKER_SOCKET "true"
# Which also turns off the "restart nginx" command that variable's absence
# would have selected, so set it explicitly: stopping nginx is enough, s6
# starts it again a moment later.
setenv NGINX_UI_NGINX_RESTART_CMD "nginx -s stop"

log "panel on ${ADMIN_HOST}:${ADMIN_PORT}, configuration in ${DATA_DIR}/nginx-ui, nginx configuration in ${DATA_DIR}/nginx"

# --- keepalived --------------------------------------------------------------
# Its own run script starts it only when this file exists, so removing it is
# how "ha.enabled: false" gets honoured after a restart with the option off.
rm -f "$KEEPALIVED_CONF"

if [ "$(opt '.ha.enabled')" = "true" ]; then
  if OPTIONS="$OPTIONS" CONF="$KEEPALIVED_CONF" "$GENERATE_KEEPALIVED_CONF"; then
    log "high availability on, virtual IP $(opt '.ha.virtual_ip') on $(opt '.ha.interface')"
  else
    log "keepalived configuration failed; the virtual IP stays down and the panel keeps running"
  fi
fi
