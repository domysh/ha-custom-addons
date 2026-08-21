#!/usr/bin/env bash
set -euo pipefail

# Overridable only so the script can be exercised outside a container; the
# add-on passes the same values it defaults to here.
: "${OPTIONS:=/data/options.json}"
: "${CONF:=/etc/keepalived/keepalived.conf}"

IFACE=$(jq -r '.ha.interface' "$OPTIONS")
VIP=$(jq -r '.ha.virtual_ip' "$OPTIONS")
VRID=$(jq -r '.ha.virtual_router_id' "$OPTIONS")
PRIORITY=$(jq -r '.ha.priority' "$OPTIONS")
AUTH_PASS=$(jq -r '.ha.auth_pass' "$OPTIONS")

if [ -z "$VIP" ]; then
  echo "ha.enabled is true but ha.virtual_ip is empty: keepalived cannot start." >&2
  exit 1
fi

# The initial state is only a hint: with preemption on (the default) keepalived
# elects the master by the highest priority in the group regardless.
STATE="BACKUP"
if [ "$PRIORITY" -ge 150 ]; then
  STATE="MASTER"
fi

mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
vrrp_instance NGINX_UI {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id ${VRID}
    priority ${PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}
    }
}
EOF
