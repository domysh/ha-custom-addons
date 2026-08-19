#!/usr/bin/env bash
# Long-running background services for the Fedora Podman Shell add-on.
# Sourced by entrypoint.sh and by addon-service; not meant to be executed.
#
# There is no systemd in here, and there is not going to be: the add-on is a
# Supervisor-managed container whose lifecycle Home Assistant owns, and a second
# init inside it would only duplicate that badly. So `systemctl start` cannot
# work, and neither can any unit file a package drops into /usr/lib/systemd.
#
# What replaces it is deliberately small: an executable file per service in
# /config/services, run in the foreground and restarted when it exits. That is
# the same contract systemd's Type=simple has, so most daemons need nothing more
# than their ExecStart line - which is why the tailscaled example ships as five
# lines. /config is a mapped host path, so the services survive add-on updates.

SERVICES_DIR="/config/services"
SERVICES_LOG_DIR="${SERVICES_DIR}/logs"
SERVICES_RUN_DIR="/run/addon-services"
SERVICES_EXAMPLE_DIR="/usr/local/share/addon-services"
# A daemon that logs every request would otherwise fill the SD card. One
# generation is kept, so the cap on disk is twice this.
SERVICE_LOG_MAX_BYTES=$((5 * 1024 * 1024))

# Names of the services present, whether running or not. Editors' leftovers and
# the log directory are skipped rather than started, and so is anything renamed
# to *.disabled, which is how a service is turned off without deleting it.
service_names() {
    local path name
    for path in "${SERVICES_DIR}"/*; do
        [ -f "${path}" ] || continue
        name="${path##*/}"
        case "${name}" in
            .* | *.disabled | *.log | *~ | *.bak | *.tmp) continue ;;
        esac
        printf '%s\n' "${name}"
    done
}

service_script() { printf '%s/%s\n' "${SERVICES_DIR}" "$1"; }
service_log() { printf '%s/%s.log\n' "${SERVICES_LOG_DIR}" "$1"; }
service_child_pidfile() { printf '%s/%s.child\n' "${SERVICES_RUN_DIR}" "$1"; }
service_supervisor_pidfile() { printf '%s/%s.supervisor\n' "${SERVICES_RUN_DIR}" "$1"; }
service_stop_flag() { printf '%s/%s.stop\n' "${SERVICES_RUN_DIR}" "$1"; }

service_pid_alive() {
    local pidfile="$1" pid
    pid="$(cat "${pidfile}" 2>/dev/null)" || return 1
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

service_is_running() { service_pid_alive "$(service_child_pidfile "$1")"; }
service_is_supervised() { service_pid_alive "$(service_supervisor_pidfile "$1")"; }

rotate_service_log() {
    local logfile="$1" size
    size="$(stat -c '%s' "${logfile}" 2>/dev/null)" || return 0
    [ "${size}" -gt "${SERVICE_LOG_MAX_BYTES}" ] || return 0
    mv -f "${logfile}" "${logfile}.1" 2>/dev/null || true
}

# Runs one service and keeps it running. Blocks, so callers background it.
#
# The restart is backed off up to a minute: a daemon that is misconfigured exits
# immediately, and restarting it in a tight loop would bury the add-on log and
# spin the CPU without ever fixing anything. A process that stayed up for a
# while is treated as healthy and gets the short delay back, so a service that
# dies once after a week does not then wait a minute.
supervise_service() {
    local name="$1"
    local script logfile stop_flag delay=1 started ended rc

    script="$(service_script "${name}")"
    logfile="$(service_log "${name}")"
    stop_flag="$(service_stop_flag "${name}")"

    mkdir -p "${SERVICES_LOG_DIR}" "${SERVICES_RUN_DIR}"
    rm -f "${stop_flag}"
    printf '%s\n' "$$" > "$(service_supervisor_pidfile "${name}")"

    while :; do
        [ -e "${stop_flag}" ] && break

        rotate_service_log "${logfile}"
        started="$(date '+%s')"

        # The child's PID is recorded so `addon-service stop` can signal the
        # daemon itself rather than this loop, which would leave it orphaned.
        # Output is tagged and goes both to the service's own log file and to
        # this process's stdout - which is the add-on log when the entrypoint
        # started it, so services show up in the Home Assistant UI too.
        {
            "${script}" &
            printf '%s\n' "$!" > "$(service_child_pidfile "${name}")"
            wait "$!"
        } 2>&1 | sed -u "s/^/[${name}] /" | tee -a "${logfile}"
        rc="${PIPESTATUS[0]}"

        rm -f "$(service_child_pidfile "${name}")"
        [ -e "${stop_flag}" ] && break

        ended="$(date '+%s')"
        if [ "$((ended - started))" -ge 60 ]; then
            delay=1
        fi

        warn "Service '${name}' exited (status ${rc}); restarting in ${delay}s. Its log: $(service_log "${name}")"
        sleep "${delay}"
        delay="$((delay * 2))"
        [ "${delay}" -gt 60 ] && delay=60
    done

    rm -f "$(service_supervisor_pidfile "${name}")" "${stop_flag}"
    log "Service '${name}' stopped."
}

# /dev/net/tun does not exist in an add-on container: Docker populates /dev with
# a small fixed set of nodes and that is not in it. Every VPN daemon needs it -
# tailscaled, wireguard-go, openvpn - and without it tailscaled silently drops
# to userspace networking, which routes nothing but its own SOCKS proxy. The
# device cgroup already allows it (full_access), so only the node is missing,
# and its major:minor is fixed by the kernel's device list.
ensure_tun_device() {
    [ -c /dev/net/tun ] && return 0

    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net
    if mknod /dev/net/tun c 10 200 2>/dev/null; then
        chmod 0600 /dev/net/tun
        log "Created /dev/net/tun, which VPN daemons such as tailscaled need."
        return 0
    fi

    warn "/dev/net/tun is missing and could not be created."
    warn "VPN daemons will not get a tunnel interface: tailscaled falls back to"
    warn "userspace networking, which only proxies its own SOCKS port. This needs"
    warn "Protection mode OFF, and the 'tun' module available on the host."
}

# Starts everything in /config/services. Called once at add-on start.
start_services() {
    local name script started=()

    [ -d "${SERVICES_DIR}" ] || return 0
    mkdir -p "${SERVICES_LOG_DIR}" "${SERVICES_RUN_DIR}"

    while read -r name; do
        [ -n "${name}" ] || continue
        script="$(service_script "${name}")"

        if [ ! -x "${script}" ]; then
            warn "Service '${name}' is not executable and was not started: chmod +x ${script}"
            continue
        fi
        # A file written on Windows has CRLF line endings, and the kernel then
        # looks for an interpreter whose name ends in a carriage return. The
        # error it produces ("no such file or directory" naming a file that is
        # plainly there) is confusing enough to be worth catching here.
        if head -c 2 "${script}" 2>/dev/null | grep -q '#!' \
            && head -n 1 "${script}" 2>/dev/null | grep -q $'\r'; then
            warn "Service '${name}' has Windows line endings; the kernel cannot run its"
            warn "shebang. Fix with: sed -i 's/\\r$//' ${script}"
            continue
        fi

        supervise_service "${name}" &
        started+=("${name}")
    done < <(service_names)

    if [ "${#started[@]}" -gt 0 ]; then
        log "Started services from ${SERVICES_DIR}: ${started[*]}"
        log "Manage them with 'addon-service', logs in ${SERVICES_LOG_DIR}"
    fi
}
