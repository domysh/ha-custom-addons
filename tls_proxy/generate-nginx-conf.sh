#!/usr/bin/env bash
set -euo pipefail

OPTIONS=/data/options.json
CONF=/etc/nginx/nginx.conf
SSL_DIR=/ssl
CERT_DIR=/etc/nginx/certs
# The Home Assistant Supervisor's internal DNS. Fixed, not exposed as an option:
# the add-on runs with host networking, so it does not get the Docker DNS of the
# "hassio" network and has to be told where to resolve add-on container names.
RESOLVER="172.30.32.3"
LISTEN_PORT=$(jq -r '.listen_port' "$OPTIONS")
HTTP_PORT=$(jq -r '.http_port' "$OPTIONS")
DEFAULT_CERT_FILE=$(jq -r '.cert_file' "$OPTIONS")
DEFAULT_KEY_FILE=$(jq -r '.key_file' "$OPTIONS")
ENABLE_IPV6=$(jq -r '.enable_ipv6' "$OPTIONS")
DEFAULT_TARGET=$(jq -r '.default_target // empty' "$OPTIONS")
DEFAULT_CERT="${CERT_DIR}/${DEFAULT_CERT_FILE}"
DEFAULT_KEY="${CERT_DIR}/${DEFAULT_KEY_FILE}"

HAS_TCP_ROUTES=$(jq -r '[.routes[] | select(.mode == "tcp")] | length' "$OPTIONS")

# The certificates have to be readable by the worker process too, which runs as
# the unprivileged "nginx" user, while in /ssl they are owned by root and
# readable by nobody else. A copy with the right ownership is kept here and
# rewritten at every start and every renewal.
sync_certs() {
  mkdir -p "$CERT_DIR"
  chown nginx:nginx "$CERT_DIR"
  chmod 500 "$CERT_DIR"

  local found=0 name tmp
  for src in "${SSL_DIR}"/*.pem; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    # Copy to a temporary file and rename: replacing the final file is then
    # atomic, so a renewal never leaves it missing or half-written for a
    # handshake that is in progress.
    tmp="${CERT_DIR}/.tmp.${name}"
    cp "$src" "$tmp"
    chown nginx:nginx "$tmp"
    chmod 400 "$tmp"
    mv -f "$tmp" "${CERT_DIR}/${name}"
    found=1
  done

  if [ "$found" = "0" ]; then
    echo "nessun file .pem trovato in ${SSL_DIR}: verifica che l'add-on Let's Encrypt abbia emesso i certificati" >&2
    return
  fi

  for old in "${CERT_DIR}"/*.pem; do
    [ -f "$old" ] || continue
    [ -f "${SSL_DIR}/$(basename "$old")" ] || rm -f "$old"
  done
}

# IPv4 + IPv6 "listen" lines for the http module.
# ipv6only is left out deliberately: it is "on" by default, and repeating it on
# more than one server for the same address:port makes nginx refuse to start
# with "duplicate listen options".
http_listen() {
  local spec="$1" flag="${2:-}"
  local d=""
  [ -n "$flag" ] && d=" default_server"
  echo "    listen ${spec}${d};"
  if [ "$ENABLE_IPV6" = "true" ]; then
    echo "    listen [::]:${spec}${d};"
  fi
}

# Certificate and key for one route, falling back to the global defaults.
route_cert() {
  local route="$1" which="$2" file
  if [ "$which" = "cert" ]; then
    file=$(jq -r '.cert_file // empty' <<<"$route")
    file="${file:-$DEFAULT_CERT_FILE}"
  else
    file=$(jq -r '.key_file // empty' <<<"$route")
    file="${file:-$DEFAULT_KEY_FILE}"
  fi
  if [ ! -f "${SSL_DIR}/${file}" ]; then
    [ "$which" = "cert" ] && echo "$DEFAULT_CERT" || echo "$DEFAULT_KEY"
    return
  fi
  echo "${CERT_DIR}/${file}"
}

# The location block shared by every HTTP route, proxying to its backend.
http_location() {
  local target="$1" target_tls="$2"
  echo "    location / {"
  echo "      set \$upstream \"${target}\";"
  if [ "$target_tls" = "true" ]; then
    echo "      proxy_pass https://\$upstream;"
    # The backend is reached by container name or internal IP, not by its
    # public hostname, so there is nothing its certificate could be verified
    # against here.
    echo "      proxy_ssl_verify off;"
  else
    echo "      proxy_pass http://\$upstream;"
  fi
  cat <<'EOF'
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_buffering off;
      # Fail fast on a backend that is down. The default here is 60 seconds,
      # and every request waiting on it holds a worker connection for that
      # long - so one dead backend can exhaust the worker connections and take
      # every *other* route down with it, which looks like the whole proxy
      # having crashed rather than one service being unreachable.
      proxy_connect_timeout 5s;
      # Long, deliberately: these apply once the backend has accepted the
      # connection, and they are what keeps websockets and long-poll requests
      # from being cut every minute.
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }
EOF
}

sync_certs

# The http module always owns the public HTTPS port. "tcp" routes (non-HTTP
# protocols) each get a dedicated port instead, so there is no intermediate hop
# and the backend sees the client's real address.
HTTPS_LISTEN_SPEC="${LISTEN_PORT} ssl"

{
  echo "user nginx;"
  echo "worker_processes auto;"
  echo "error_log /dev/stderr notice;"
  echo "pid /var/run/nginx.pid;"
  # 1024 is nginx's conservative default and is the ceiling that turns one
  # misbehaving backend into an outage for everything: with long-lived
  # connections held open per route, a few hundred stuck requests are enough to
  # refuse new ones on every domain. The memory cost of raising it is a few MB.
  echo "worker_rlimit_nofile 16384;"
  echo "events { worker_connections 4096; }"
  echo ""

  if [ "$HAS_TCP_ROUTES" -gt 0 ]; then
    # --- stream: non-HTTP routes, one dedicated port each ------------------
    # SNI is neither needed nor used here: the public port already identifies
    # the service. TLS is not terminated, the bytes pass through untouched, and
    # the backend presents its own certificate.
    echo "stream {"
    echo "  resolver ${RESOLVER} valid=30s;"
    echo "  log_format tcp '\$remote_addr [\$time_local] :\$server_port -> \$upstream_addr';"
    echo "  access_log /dev/stdout tcp;"
    jq -c '.routes[] | select(.mode == "tcp")' "$OPTIONS" | while read -r route; do
      DOMAIN=$(jq -r '.domain' <<<"$route")
      TARGET=$(jq -r '.target' <<<"$route")
      TCP_PORT=$(jq -r '.tcp_port // empty' <<<"$route")
      TARGET_TLS=$(jq -r '.target_tls // false' <<<"$route")
      if [ -z "$TCP_PORT" ] || [ "$TCP_PORT" = "0" ]; then
        echo "skipping tcp route ${DOMAIN}: no tcp_port set (a tcp route needs a dedicated public port)" >&2
        continue
      fi
      echo ""
      echo "  # ${DOMAIN}"
      echo "  server {"
      echo "    listen ${TCP_PORT};"
      [ "$ENABLE_IPV6" = "true" ] && echo "    listen [::]:${TCP_PORT};"
      echo "    set \$tcp_upstream \"${TARGET}\";"
      echo "    proxy_pass \$tcp_upstream;"
      # Same reasoning as the http routes: a dead backend must not hold the
      # connection for the default minute.
      echo "    proxy_connect_timeout 5s;"
      [ "$TARGET_TLS" = "true" ] && echo "    proxy_ssl on;"
      echo "  }"
    done
    echo "}"
    echo ""
  fi

  # --- http: TLS terminated here, routing by the Host header -------------
  # Unlike SNI, the Host header is always present: a client that connects by IP
  # address - another reverse proxy in front of this one, typically - still
  # reaches the right service.
  echo "http {"
  echo "  resolver ${RESOLVER} valid=30s;"
  echo "  access_log /dev/stdout combined;"
  echo "  server_names_hash_bucket_size 128;"
  echo "  client_max_body_size 0;"
  echo ""
  echo "  map \$http_upgrade \$connection_upgrade {"
  echo "    default upgrade;"
  echo "    '' close;"
  echo "  }"
  echo ""

  # Default HTTPS vhost: an unknown Host, or a client arriving by IP with no
  # configured Host.
  echo "  server {"
  http_listen "$HTTPS_LISTEN_SPEC" "default_server"
  echo "    ssl_certificate ${DEFAULT_CERT};"
  echo "    ssl_certificate_key ${DEFAULT_KEY};"
  if [ -n "$DEFAULT_TARGET" ]; then
    http_location "$DEFAULT_TARGET" "false"
  else
    echo "    return 444;"
  fi
  echo "  }"

  # One HTTPS vhost per non-tcp route
  jq -c '.routes[] | select(.mode != "tcp")' "$OPTIONS" | while read -r route; do
    DOMAIN=$(jq -r '.domain' <<<"$route")
    TARGET=$(jq -r '.target' <<<"$route")
    TARGET_TLS=$(jq -r '.target_tls // false' <<<"$route")
    echo "  server {"
    http_listen "$HTTPS_LISTEN_SPEC"
    echo "    server_name ${DOMAIN};"
    echo "    ssl_certificate $(route_cert "$route" cert);"
    echo "    ssl_certificate_key $(route_cert "$route" key);"
    http_location "$TARGET" "$TARGET_TLS"
    echo "  }"
  done

  # Cleartext vhosts on the HTTP port
  echo "  server {"
  http_listen "$HTTP_PORT" "default_server"
  echo "    return 444;"
  echo "  }"

  jq -c '.routes[] | select(.mode != "tcp") | select(.enable_http == true)' "$OPTIONS" | while read -r route; do
    DOMAIN=$(jq -r '.domain' <<<"$route")
    TARGET=$(jq -r '.target' <<<"$route")
    TARGET_TLS=$(jq -r '.target_tls // false' <<<"$route")
    echo "  server {"
    http_listen "$HTTP_PORT"
    echo "    server_name ${DOMAIN};"
    http_location "$TARGET" "$TARGET_TLS"
    echo "  }"
  done

  echo "}"
} > "$CONF"

nginx -t -c "$CONF"
