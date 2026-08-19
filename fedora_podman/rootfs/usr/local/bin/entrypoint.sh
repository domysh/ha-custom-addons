#!/usr/bin/env bash
# Entrypoint for the Fedora Podman Shell add-on.
#
# Reads the add-on options, validates them, configures SSH and Podman, and then
# exec's sshd in the foreground. Anything that would leave the add-on running
# in a state the user cannot use or cannot diagnose is a hard failure with an
# actionable message; anything that only affects convenience is a warning.
set -euo pipefail

OPTIONS_FILE="/data/options.json"
# app_config is mounted at /config and survives add-on updates, unlike the
# container filesystem.
PERSIST_DIR="/config"
SSH_KEY_DIR="${PERSIST_DIR}/ssh"

# shellcheck source=./configure-ssh.sh
source /usr/local/bin/configure-ssh.sh
# shellcheck source=./configure-podman.sh
source /usr/local/bin/configure-podman.sh
# shellcheck source=./configure-persistence.sh
source /usr/local/bin/configure-persistence.sh
# shellcheck source=./configure-services.sh
source /usr/local/bin/configure-services.sh
# shellcheck source=./inspect-runtime.sh
source /usr/local/bin/inspect-runtime.sh

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

fatal() {
    printf '\n[%s] FATAL: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
    shift
    # Remaining arguments are printed as guidance lines, so the add-on log tells
    # the user what to actually do rather than just what went wrong.
    for line in "$@"; do
        printf '  %s\n' "$line" >&2
    done
    printf '\n' >&2
    exit 1
}

# --- Options -----------------------------------------------------------------

read_options() {
    [ -f "${OPTIONS_FILE}" ] || fatal \
        "Add-on options file ${OPTIONS_FILE} not found." \
        "This should never happen; the Supervisor writes it before start." \
        "Try reinstalling the add-on."

    SSH_PORT="$(jq -r '.ssh_port' "${OPTIONS_FILE}")"
    TIMEZONE="$(jq -r '.timezone' "${OPTIONS_FILE}")"
    PODMAN_STORAGE_PATH="$(jq -r '.podman_storage_path' "${OPTIONS_FILE}")"
    AUTOSTART_CONTAINERS="$(jq -r '.autostart_containers' "${OPTIONS_FILE}")"
    STARTUP_COMPOSE_FILE="$(jq -r '.startup_compose_file // empty' "${OPTIONS_FILE}")"
    STARTUP_COMMAND="$(jq -r '.startup_command // empty' "${OPTIONS_FILE}")"

    # Trailing slashes would end up doubled in every derived path below.
    PODMAN_STORAGE_PATH="${PODMAN_STORAGE_PATH%/}"
}

validate_options() {
    # Public-key auth is the only way in - password auth is disabled
    # unconditionally - so no keys means an add-on nobody can log into.
    local key_count
    key_count="$(jq -r '.authorized_keys | length' "${OPTIONS_FILE}")"
    if [ "${key_count}" -eq 0 ]; then
        fatal \
            "No SSH public keys configured, so nothing could log in." \
            "Add your public key to the 'authorized_keys' option, for example:" \
            "  authorized_keys:" \
            "    - ssh-ed25519 AAAAC3Nza... you@yourmachine" \
            "Generate one with: ssh-keygen -t ed25519 -C 'home-assistant'" \
            "and paste the contents of the resulting .pub file."
    fi

    # Catch the common mistake of pasting a *private* key, or a path, instead of
    # the public key itself. A key sshd cannot parse is silently ignored, which
    # looks exactly like a working add-on that refuses your login.
    local key
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        case "${key}" in
            ssh-* | ecdsa-* | sk-ssh-* | sk-ecdsa-*) ;;
            "-----BEGIN "*)
                fatal \
                    "'authorized_keys' contains what looks like a PRIVATE key." \
                    "Never paste a private key here. Use the matching .pub file," \
                    "whose contents start with 'ssh-ed25519' or 'ssh-rsa'."
                ;;
            *)
                fatal \
                    "'authorized_keys' contains an entry that is not an SSH public key:" \
                    "  ${key}" \
                    "Each entry must be one full line from a .pub file, starting with" \
                    "a key type such as 'ssh-ed25519', 'ssh-rsa' or 'ecdsa-sha2-*'."
                ;;
        esac
    done < <(jq -r '.authorized_keys[]' "${OPTIONS_FILE}")

    # Home Assistant OS uses 22222 for its own debug SSH. With host_network the
    # add-on binds on the host's stack directly, so reusing it cannot work.
    if [ "${SSH_PORT}" = "22222" ]; then
        fatal \
            "SSH port 22222 is reserved by Home Assistant OS for its own debug SSH." \
            "Pick a different 'ssh_port' (the default is 2222)."
    fi

    [ -e "/usr/share/zoneinfo/${TIMEZONE}" ] || fatal \
        "Timezone '${TIMEZONE}' is not a known zoneinfo name." \
        "Use a full IANA name such as 'Europe/Rome' or 'America/New_York'." \
        "The full list is under /usr/share/zoneinfo."

    # The whole point of the storage path is surviving add-on updates. Anywhere
    # outside a mapped host path lives in the container's writable layer, which
    # is destroyed on every update - taking all images and containers with it.
    #
    # The `?*` is not decoration: it demands at least one path component below
    # the mapped root, so a mapped root itself is rejected. Podman would chmod
    # 0700 whatever it is given, and `addon-reset` would delete it - neither is
    # something to do to /config, which also holds the SSH host keys and the
    # persistent system layer.
    case "${PODMAN_STORAGE_PATH}/" in
        /config/?*/ | /share/?*/ | /media/?*/ | /backup/?*/ | /homeassistant/?*/ | /app_configs/?*/) ;;
        *)
            fatal \
                "'podman_storage_path' (${PODMAN_STORAGE_PATH}) is not a directory on a persistent mapped path." \
                "Everything outside a mapped path is destroyed on every add-on update," \
                "and a mapped path's own root must not be used: it holds other things." \
                "Use a subdirectory of one of: /config, /share, /media, /backup," \
                "/homeassistant, /app_configs. The default is /config/podman."
            ;;
    esac
}

# --- Reset -------------------------------------------------------------------

# Carries out a reset queued by `addon-reset` (see that script for why it is
# queued rather than done on the spot).
#
# Order matters and is the reason this runs where it does in main(): the system
# layer must go before it is overlay-mounted, and the Podman storage before
# Podman is configured and its directories recreated.
RESET_REQUEST_FILE="/data/reset-request"

# Deleting a directory that other things depend on is worth being careful
# about, so this refuses to act on anything it was not built to delete: the
# paths come from a fixed list here, never from the request file, which only
# names a target.
reset_target() {
    local target="$1"
    local path

    case "${target}" in
        podman)
            # validate_options has already rejected a mapped root, so this is a
            # subdirectory and not, say, /config itself.
            log "Reset: deleting Podman storage at ${PODMAN_STORAGE_PATH}"
            rm -rf -- "${PODMAN_STORAGE_PATH}"
            ;;
        system)
            log "Reset: deleting the persistent system layer at ${PERSIST_DIR}/system"
            rm -rf -- "${PERSIST_DIR}/system"
            # Layers retired by a base image change, which would otherwise sit
            # there for ever after the user has asked for a clean slate.
            for path in "${PERSIST_DIR}"/system.fedora-*; do
                [ -e "${path}" ] || continue
                log "Reset: deleting retired system layer ${path}"
                rm -rf -- "${path}"
            done
            ;;
        autostart)
            log "Reset: forgetting which containers were running"
            rm -f -- "$(autostart_state_file)"
            ;;
        ssh)
            log "Reset: deleting the SSH host keys in ${SSH_KEY_DIR}"
            log "New ones are generated below; clients will report a changed fingerprint."
            rm -rf -- "${SSH_KEY_DIR}"
            ;;
        *)
            warn "Reset: ignoring unknown target '${target}' in ${RESET_REQUEST_FILE}"
            ;;
    esac
}

apply_reset_request() {
    [ -s "${RESET_REQUEST_FILE}" ] || return 0

    local -a targets=()
    mapfile -t targets < <(sed '/^$/d' "${RESET_REQUEST_FILE}")

    # Removed before anything is deleted, not after: a reset that dies halfway
    # through - or that itself is what prevents the add-on from starting - must
    # not run again on the next start, which would be an unbreakable loop with
    # the add-on deleting its own state for ever.
    rm -f -- "${RESET_REQUEST_FILE}"

    log "Applying the reset queued with addon-reset: ${targets[*]}"
    local target
    for target in "${targets[@]}"; do
        reset_target "${target}"
    done
    log "Reset done. What was deleted is gone; the add-on continues starting normally."
}

# --- System basics -----------------------------------------------------------

configure_timezone() {
    ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    printf '%s\n' "${TIMEZONE}" > /etc/timezone
    # Exported into interactive sessions too, so timestamps in the shell match
    # the ones in the add-on log.
    printf 'export TZ="%s"\n' "${TIMEZONE}" > /etc/profile.d/20-addon-timezone.sh
    log "Timezone set to ${TIMEZONE}"
}

# Makes the host's root filesystem available at /host.
#
# An add-on manifest has no way to declare a bind mount of an arbitrary host
# path: the Supervisor builds the mount list itself from a fixed set of map
# types, and there is no escape hatch for "/". What it can do is share the
# host's PID namespace (host_pid: true), which makes PID 1 the host's init -
# and /proc/<pid>/root is resolved in that process's mount namespace, so
# /proc/1/root is the host's real root filesystem.
#
# /host is a symlink to that magic link, which is what makes the host's own
# submounts (/mnt/data above all) readable through it. See setup_host_access
# for why a bind mount cannot do the same.
HOST_DIR="/host"

# True only when /proc/1/root really is a different filesystem root than ours.
#
# host_pid is silently ignored by the Supervisor while Protection mode is on
# (it applies `pid_mode=host` only `if not self.app.protected`). With it off,
# PID 1 inside the container is this add-on's own init, so /proc/1/root is the
# *container's* root - and exposing that as /host would produce a convincing
# but completely useless copy of the add-on's own filesystem. Comparing device
# and inode tells the two apart.
host_namespace_is_shared() {
    local our_root host_root
    our_root="$(stat -c '%d:%i' / 2>/dev/null)" || return 1
    host_root="$(stat -c '%d:%i' /proc/1/root/ 2>/dev/null)" || return 1

    log "PID 1 is '$(cat /proc/1/comm 2>/dev/null || echo unknown)'; / is ${our_root}, /proc/1/root is ${host_root}"

    if [ "${our_root}" = "${host_root}" ]; then
        return 1
    fi

    # Comparing device and inode is not sufficient on its own: it only proves
    # the two roots are different filesystems, not that the second one is the
    # *host*. If /proc/1 turns out to be some other container built from the
    # same image, the identifiers differ while the content is ours. Comparing
    # the os-release files catches that, because Home Assistant OS obviously
    # does not identify itself as this add-on's Fedora image.
    if [ -r /proc/1/root/etc/os-release ] && [ -r /etc/os-release ] \
        && cmp -s /proc/1/root/etc/os-release /etc/os-release
    then
        warn "/proc/1/root has this add-on's own os-release, so PID 1 is not the host's"
        warn "init but a container built from the same image."
        return 1
    fi

    return 0
}

setup_host_access() {
    if ! host_namespace_is_shared; then
        warn "Not exposing ${HOST_DIR}: /proc/1/root is this container's own root,"
        warn "not the host's, so exposing it would just duplicate the add-on's"
        warn "filesystem under a misleading name."
        warn "Cause: the host PID namespace is not actually shared. The Supervisor"
        warn "ignores 'host_pid' while Protection mode is ON - turn it off in the"
        warn "add-on's Info tab and restart. (The same switch gates full device"
        warn "access and the Docker socket.)"
        return 0
    fi

    # A symlink, deliberately - NOT a bind mount, which is what versions 1.3.0
    # to 1.10.1 used and got wrong in two ways at once:
    #
    #  1. /proc/<pid>/root is a magic link the kernel resolves in the target's
    #     mount namespace, so reading *through* it crosses into the host's own
    #     submounts and /host/mnt/data is the real thing. A bind mount copies
    #     the single mount instead, and the host's submounts are not in our
    #     namespace, so they read as empty directories.
    #  2. mount(8) canonicalises its source in userspace before calling
    #     mount(2), and `readlink /proc/1/root` is literally "/" - so the bind
    #     resolved to *our own* root and cheerfully presented the add-on's
    #     filesystem as the host's.
    #
    # Both verified experimentally; --no-canonicalize does not help, it just
    # makes the mount fail.
    if mountpoint -q "${HOST_DIR}" 2>/dev/null; then
        umount -R "${HOST_DIR}" 2>/dev/null || true
    fi

    if [ -L "${HOST_DIR}" ] || [ ! -e "${HOST_DIR}" ]; then
        ln -snf /proc/1/root "${HOST_DIR}"
    elif rmdir "${HOST_DIR}" 2>/dev/null; then
        # rmdir refuses a non-empty directory, which is the safety property
        # relied on here: `ln -sfn` would not fail on one, it would quietly
        # create the link *inside* it.
        ln -snf /proc/1/root "${HOST_DIR}"
    else
        warn "${HOST_DIR} exists, is not a symlink and is not empty; leaving it alone."
        return 0
    fi

    # Confirm what we actually ended up pointing at, rather than assuming.
    if [ ! -r "${HOST_DIR}/etc/os-release" ]; then
        warn "${HOST_DIR} is not readable: cannot reach the host's root filesystem."
        warn "This needs Protection mode to be OFF for the add-on."
        return 0
    fi
    if cmp -s "${HOST_DIR}/etc/os-release" /etc/os-release; then
        warn "${HOST_DIR} resolves to this add-on's own filesystem, not the host's."
        warn "Not what was intended; report this with the add-on log."
        return 0
    fi

    local host_name
    host_name="$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' "${HOST_DIR}/etc/os-release" 2>/dev/null)"
    log "Host filesystem available at ${HOST_DIR} (${host_name:-unknown host OS}), submounts included"
}

write_motd() {
    cat > /etc/motd <<EOF

 Fedora Podman Shell add-on

   Podman storage : ${PODMAN_STORAGE_PATH}
   Storage driver : ${PODMAN_STORAGE_DRIVER}${PODMAN_MOUNT_PROGRAM:+ (via fuse-overlayfs)}
   Persistent     : /config /share /media /backup /homeassistant
                    plus /usr /etc /opt /root /var, so dnf installs stay
   Host filesystem: /host   (the REAL host root - changes there are permanent)
   Host shell     : nsenter -t 1 -m -u -i -n -p -- /bin/sh
   Host Docker    : /run/docker.sock (read-only inspection, NOT used by podman)

   podman info            check the container stack
   podman-compose --help  compose files
   podman-diag            dump podman + host firewall state (read-only),
                          the first thing to run when a published port
                          does not answer or 'podman logs' stays empty
   addon-reset --help     wipe the podman storage, the persistent system
                          layer or the host keys, at the next start
   addon-service list     background daemons (there is no systemd here:
                          'addon-service examples' has a ready-made
                          tailscaled to start from)

   Anything outside the persistent paths above is lost when this add-on is
   updated, rebuilt or removed.

EOF
}

# --- Container autostart -----------------------------------------------------

# There is no systemd in here, so nothing applies Podman's --restart policies
# when the add-on starts: podman-restart.service is what does it on a normal
# Fedora system, and there is no service manager to run it. The two functions
# below replace it.
#
# Restart policies alone are not enough, though. What is expected of an add-on
# is that the containers that were running before it stopped are running again
# after it starts - and a container created with a plain `podman run -d` has
# the restart policy "no", so a policy-only rule (which is all this used to do)
# silently left exactly those behind. So the set of running containers is
# recorded while the add-on runs, and that record is used at the next start on
# top of the restart policies.
#
# The record lives with the rest of Podman's state, under the graph root, so it
# survives add-on updates and is reset by resetting the storage.
autostart_state_file() { printf '%s/autostart.list\n' "${PODMAN_STORAGE_PATH}"; }

# Names the next start should bring up: everything asked for by restart policy,
# plus everything that was running when the record was last written. Duplicates
# are expected and removed by the caller.
containers_to_autostart() {
    local policy
    # "unless-stopped" is included: Podman treats it as "always" across a
    # reboot, and this function is that reboot as far as the containers are
    # concerned. "on-failure" is not - it is about the container's own exit
    # code, not about us restarting.
    for policy in always unless-stopped; do
        podman ps --all --filter "restart-policy=${policy}" --format '{{.Names}}' 2>/dev/null || true
    done
    cat "$(autostart_state_file)" 2>/dev/null || true
}

# Nothing in here is fatal, and it is run in the background (see main), because
# a broken compose file must not cost you the SSH access you need to fix it -
# and neither must a slow one: a compose project that pulls a few images can
# take minutes, which would otherwise be minutes of no SSH.
start_containers() {
    if [ "${AUTOSTART_CONTAINERS}" = "true" ]; then
        local -a wanted=() to_start=() gone=()
        local name existing running

        mapfile -t wanted < <(containers_to_autostart | sed '/^$/d' | sort -u)

        if [ "${#wanted[@]}" -gt 0 ]; then
            # One query each rather than one per container: podman start on an
            # already-running container is harmless, but reporting accurately
            # what was done needs the before-state.
            existing="$(podman ps --all --format '{{.Names}}' 2>/dev/null || true)"
            running="$(podman ps --format '{{.Names}}' 2>/dev/null || true)"

            for name in "${wanted[@]}"; do
                if ! grep -qxF "${name}" <<< "${existing}"; then
                    gone+=("${name}")
                elif ! grep -qxF "${name}" <<< "${running}"; then
                    to_start+=("${name}")
                fi
            done
        fi

        if [ "${#to_start[@]}" -gt 0 ]; then
            log "Starting containers that were running before, or ask to always run: ${to_start[*]}"
            podman start "${to_start[@]}" \
                || warn "Some containers failed to start; check 'podman ps -a' and 'podman logs'."
        fi

        # Containers in the record that no longer exist were removed while the
        # add-on was down (or by a compose down). Saying so once is useful; the
        # record is rewritten by the tracker below, so this does not repeat.
        if [ "${#gone[@]}" -gt 0 ]; then
            log "Previously running containers no longer exist, nothing to start for: ${gone[*]}"
        fi
    fi

    if [ -n "${STARTUP_COMPOSE_FILE}" ]; then
        if [ -f "${STARTUP_COMPOSE_FILE}" ]; then
            log "Bringing up compose project: ${STARTUP_COMPOSE_FILE}"
            podman-compose -f "${STARTUP_COMPOSE_FILE}" up -d \
                || warn "podman-compose failed for ${STARTUP_COMPOSE_FILE}; check the add-on log above."
        else
            warn "startup_compose_file '${STARTUP_COMPOSE_FILE}' does not exist, skipping."
            warn "Note that the path must be one visible inside the add-on, e.g. /share/compose/stack.yml."
        fi
    fi

    if [ -n "${STARTUP_COMMAND}" ]; then
        log "Running startup_command"
        bash -lc "${STARTUP_COMMAND}" || warn "startup_command exited non-zero."
    fi
}

# Keeps the record of running containers up to date, for the next start to use.
#
# Polling rather than watching `podman events`: the events stream dies with any
# podman hiccup and would then leave the record frozen without anything saying
# so, while a poll simply picks up again. The file is only rewritten when the
# set actually changes, so an idle add-on does not write to the SD card at all.
#
# A failed query is skipped rather than recorded: treating "podman is briefly
# unavailable" as "nothing is running" would erase the record and lose the
# autostart set on the next boot.
track_running_containers() {
    local current previous="" state_file
    state_file="$(autostart_state_file)"

    while :; do
        if current="$(podman ps --format '{{.Names}}' 2>/dev/null)"; then
            current="$(printf '%s\n' "${current}" | sed '/^$/d' | sort)"
            if [ "${current}" != "${previous}" ]; then
                if printf '%s\n' "${current}" | sed '/^$/d' > "${state_file}.tmp" \
                    && mv "${state_file}.tmp" "${state_file}"
                then
                    previous="${current}"
                fi
            fi
        fi
        sleep 20
    done
}

# --- Main --------------------------------------------------------------------

main() {
    log "Starting Fedora Podman Shell add-on"

    read_options
    validate_options

    # Before the system layer is mounted and before Podman's directories are
    # recreated, which is the only moment either can be deleted.
    apply_reset_request

    # Must come first: everything below writes to /etc, and those writes have
    # to land in the persistent upper layer rather than under it.
    setup_persistent_system "${PERSIST_DIR}/system"

    configure_timezone

    configure_ssh
    configure_podman

    report_runtime_state
    setup_host_access
    ensure_tun_device

    write_motd

    # Backgrounded on purpose: see start_containers. Its output still goes to
    # the add-on log, interleaved with sshd's. tini (PID 1) reaps it.
    start_containers &
    # Started after it, so the record is not overwritten from the empty state
    # that exists while the containers above are still coming up.
    { sleep 60; track_running_containers; } &

    # Same reasoning as start_containers: a service that fails or hangs must not
    # cost you the shell you need to fix it. Each service gets its own
    # supervising background process.
    start_services

    log "SSH is listening on port ${SSH_PORT} (public-key authentication only)"
    # exec: sshd becomes the process the Supervisor watches, so stopping the
    # add-on stops it directly and its log goes straight to the add-on log.
    # -D keeps it in the foreground, -e sends the log to stderr.
    exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
}

main "$@"
