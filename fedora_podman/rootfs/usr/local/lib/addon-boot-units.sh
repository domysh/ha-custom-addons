#!/usr/bin/env bash
# What the add-on does with systemd units when it starts.
# Sourced by entrypoint.sh, and by the Dockerfile for the baseline; not meant
# to be executed on its own.
#
# The service manager itself is docker-systemctl-replacement (systemctl3.py,
# EUPL-1.2), installed at /usr/bin/systemctl behind a thin wrapper - see
# /usr/lib/addon-systemctl/systemctl for why it is there and not a home-grown
# one any more. This file is only the add-on's side of it: keeping that
# /usr/bin/systemctl in place, deciding which units this add-on starts, and
# getting their output into the Home Assistant add-on log.

# Paths, overridable only so this can be exercised outside a container; nothing
# sets them in the add-on.
: "${ADDON_SYSTEMCTL:=/usr/bin/systemctl}"
: "${ADDON_SYSTEMCTL_DIR:=/usr/lib/addon-systemctl}"
: "${ADDON_BIN_DIR:=/usr/bin}"
: "${ADDON_UNIT_ETC_DIR:=/etc/systemd/system}"
: "${ADDON_UNIT_SEARCH_PATH:=/etc/systemd/system:/run/systemd/system:/usr/local/lib/systemd/system:/usr/lib/systemd/system:/lib/systemd/system}"
: "${ADDON_JOURNAL_DIR:=/var/log/journal}"
# What the base image came with enabled, written when the image is built. On
# /usr, from the image: an update brings the new image's list with it.
: "${ADDON_BASELINE_FILE:=${ADDON_SYSTEMCTL_DIR}/image-enabled}"
# What `systemctl enable` was run on here, written by the wrapper. On /etc, so
# it sits on the persistent layer next to the links themselves.
: "${ADDON_SYSTEMCTL_OPTIN_FILE:=/etc/addon-systemctl/enabled}"
# The same record as kept by the add-on's own service manager before 2.1.0.
# Still read, so a unit enabled under the old one keeps counting as yours.
: "${ADDON_LEGACY_OPTIN_FILE:=/etc/addon-units/enabled}"
# Upstream appends to its log files for ever, and /var is persistent; the old
# runner rotated at 5 MB, and so does this, once per start.
: "${ADDON_JOURNAL_MAX_BYTES:=$((5 * 1024 * 1024))}"

declare -F log >/dev/null || log() { printf '%s\n' "$*"; }
declare -F warn >/dev/null || warn() { printf 'WARNING: %s\n' "$*" >&2; }

# --- /usr/bin/systemctl stays ours --------------------------------------------
#
# /usr is a persistent overlay (configure-persistence.sh), and that cuts both
# ways here. An install that ran `dnf upgrade` before rpm was told to leave
# /usr/bin/systemctl alone (/etc/rpm/macros.addon-systemctl, new in 2.1.0) has
# systemd's real binary in its upper layer - and the upper layer shadows the
# image for ever, so no image update could put the replacement back on its own.
# Any later accident (a `cp`, an rpm run without the macro) would stick the
# same way.
#
# So this checks the merged view on every start and puts the link back if it
# is anything else. It runs after the overlay is mounted, on purpose: the
# kernel's overlayfs documentation calls changing the upper directory of a
# mounted overlay undefined, so the repair goes through the overlay like any
# other write, rather than deleting files under its feet. A symlink rather
# than a copy, so that what lands in the upper layer points at the image's
# own file and an update of the wrapper still takes effect. A whiteout (what
# `rpm -e systemd` leaves for a lower-layer file) reads as "missing" here and
# is repaired the same way.
ensure_service_manager() {
    local name link target current
    for name in systemctl journalctl; do
        link="${ADDON_BIN_DIR}/${name}"
        target="${ADDON_SYSTEMCTL_DIR}/${name}"
        current="$(readlink -- "${link}" 2>/dev/null || true)"
        [ "${current}" = "${target}" ] && continue

        if [ -n "${current}" ]; then
            current="a symlink to ${current}"
        elif [ -e "${link}" ]; then
            current="a $(stat -c '%s' -- "${link}" 2>/dev/null || echo '?')-byte file, most likely systemd's own"
        else
            current="missing"
        fi
        if ln -sfn -- "${target}" "${link}" 2>/dev/null; then
            log "${link} was ${current}; restored the add-on's service manager there."
        else
            warn "${link} is ${current}, and could not be replaced with ${target}."
            warn "Package scriptlets will not be able to start or stop services."
        fi
    done
}

# --- what the add-on starts --------------------------------------------------
#
# "Enabled" and "started by this add-on" are not the same set.
#
# A Fedora image arrives with units already linked into /etc/systemd/system:
# getty@tty1, the systemd-* services, first-boot maintenance like
# selinux-autorelabel-mark and rpmdb-rebuild - and, because this add-on
# installs openssh-server, sshd.service. Nobody chose those here; they are what
# the packages' presets did while the image was being built, for a machine that
# boots a real systemd. Starting them ranges from noise to fatal (sshd, see the
# wrapper), so the set the image came with is recorded at build time and the
# add-on starts what was enabled *since*: by you, or by a package installed at
# runtime. `systemctl enable` is recorded by the wrapper, so enabling a unit
# the image already had works too, and means it.
#
# Why the links are read here rather than taken from upstream's
# `list-unit-files`: that lists unit *files*, so a template shows up as
# getty@.service and its enabled instances (getty@tty1, wg-quick@wg0,
# openvpn-client@foo) do not show up at all. The links in .wants/.requires are
# exactly what `enable` writes, instance names included, and upstream's
# `is-enabled` is then asked about each candidate, so what is started is what
# upstream itself considers enabled.
#
# Only services: upstream's init loop does have socket units, but nothing in
# here has ever started sockets or timers at boot, and a socket from a
# package preset would start listening on the host's own network.

# Every *.service linked into some target's .wants or .requires.
enabled_unit_links() {
    local dir link
    for dir in "${ADDON_UNIT_ETC_DIR}"/*.wants "${ADDON_UNIT_ETC_DIR}"/*.requires; do
        [ -d "${dir}" ] || continue
        for link in "${dir}"/*.service; do
            [ -L "${link}" ] || [ -e "${link}" ] || continue
            printf '%s\n' "${link##*/}"
        done
    done | sort -u
}

# Run by the Dockerfile, once, as the last step: every dnf before it may have
# enabled something.
boot_units_write_baseline() {
    mkdir -p "${ADDON_BASELINE_FILE%/*}"
    enabled_unit_links > "${ADDON_BASELINE_FILE}"
    printf 'Recorded %s units the image came with enabled.\n' \
        "$(wc -l < "${ADDON_BASELINE_FILE}" | tr -d ' ')"
}

unit_opted_in() {
    grep -Fxq -- "$1" "${ADDON_SYSTEMCTL_OPTIN_FILE}" 2>/dev/null \
        || grep -Fxq -- "$1" "${ADDON_LEGACY_OPTIN_FILE}" 2>/dev/null
}

# systemd's own plumbing, which only means something under a real systemd.
# The baseline covers what the image shipped; this covers the same units
# arriving later - `dnf reinstall systemd` runs `systemctl preset-all`, which
# would enable them all at once. Upstream skips much the same list in its own
# `default` (igno_always). Unlike sshd, an explicit `systemctl enable` wins.
unit_is_plumbing() {
    case "$1" in
        systemd-* | dbus* | getty@* | serial-getty@* | console-getty* \
            | container-getty@* | autovt@* | kmod* | rpmdb-* | selinux-*)
            return 0 ;;
    esac
    return 1
}

# Sets BOOT_SKIP_REASON when the answer is no.
unit_starts_at_boot() {
    local name="$1"
    BOOT_SKIP_REASON=""

    # Never, whatever was enabled: see /usr/lib/addon-systemctl/systemctl.
    case "${name}" in
        sshd.service | ssh.service | sshd@*.service)
            BOOT_SKIP_REASON="the add-on runs its own sshd; set its port with the ssh_port option"
            return 1 ;;
    esac

    unit_opted_in "${name}" && return 0

    if grep -Fxq -- "${name}" "${ADDON_BASELINE_FILE}" 2>/dev/null; then
        BOOT_SKIP_REASON="the base image came with it enabled"
        return 1
    fi
    if unit_is_plumbing "${name}"; then
        BOOT_SKIP_REASON="systemd's own plumbing"
        return 1
    fi
    return 0
}

# Prints the units to start, one per line, and logs what it leaves alone.
select_boot_units() {
    local name state skipped=0 other=()
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        if ! unit_starts_at_boot "${name}"; then
            case "${BOOT_SKIP_REASON}" in
                "the add-on runs its own sshd"*) log "Not starting ${name}: ${BOOT_SKIP_REASON}." >&2 ;;
                *) skipped=$((skipped + 1)) ;;
            esac
            continue
        fi
        # A link can outlive its unit (the package was removed) or disagree
        # with the unit's [Install] section; upstream decides, and says why.
        # `|| true`: is-enabled exits non-zero for anything but enabled, and
        # under the entrypoint's errexit that would end the selection silently
        # at the first such unit. Its output is still wanted, for the warning.
        state="$("${ADDON_SYSTEMCTL}" is-enabled "${name}" 2>/dev/null)" || true
        state="${state%%$'\n'*}"
        if [ "${state}" = "enabled" ]; then
            printf '%s\n' "${name}"
        else
            other+=("${name} (${state:-not found})")
        fi
    done < <(enabled_unit_links)

    if [ "${#other[@]}" -gt 0 ]; then
        warn "Linked but not enabled according to systemctl, so not started: ${other[*]}" >&2
        warn "'systemctl disable <unit>' clears a stale link." >&2
    fi
    if [ "${skipped}" -gt 0 ]; then
        log "Left alone (enabled by the base image, or systemd's own plumbing): ${skipped} units." >&2
        log "'systemctl enable <unit>' makes one of them start here too." >&2
    fi
    return 0
}

# --- their logs, in the add-on log -------------------------------------------
#
# Upstream writes each service's stdout and stderr to
# /var/log/journal/<unit file>.log, and `journalctl -u` reads that. Its init
# loop can also copy those files to its own stdout, and that was tried first:
# it opens them at offset 0, so on a persistent /var every start replays the
# unit's whole history into the add-on log. So the loop's stdout goes to
# /dev/null and a `tail -n 0 -F` per file does the forwarding instead, from
# wherever the file ends now. -F rather than -f because the file may not exist
# yet, and because the rotation below replaces it.
#
# The file is named after the unit *file*: an instance of a template logs to
# the template's file (wg-quick@.service.log), shared by all its instances.
unit_log_file() {
    local name="$1" dir template
    local -a dirs=()
    IFS=: read -r -a dirs <<< "${ADDON_UNIT_SEARCH_PATH}"
    for dir in "${dirs[@]}"; do
        [ -e "${dir}/${name}" ] && { printf '%s/%s.log\n' "${ADDON_JOURNAL_DIR}" "${name}"; return 0; }
    done
    case "${name}" in
        *@*.service)
            template="${name%%@*}@.service"
            printf '%s/%s.log\n' "${ADDON_JOURNAL_DIR}" "${template}"
            return 0 ;;
    esac
    printf '%s/%s.log\n' "${ADDON_JOURNAL_DIR}" "${name}"
}

rotate_unit_logs() {
    local file size
    for file in "${ADDON_JOURNAL_DIR}"/*.log; do
        [ -f "${file}" ] || continue
        size="$(stat -c '%s' -- "${file}" 2>/dev/null || echo 0)"
        [ "${size}" -gt "${ADDON_JOURNAL_MAX_BYTES}" ] || continue
        mv -f -- "${file}" "${file}.1" 2>/dev/null || true
    done
}

forward_unit_log() {
    local label="$1" file="$2" line
    tail -n 0 -F -- "${file}" 2>/dev/null | while IFS= read -r line; do
        printf '[%s] %s\n' "${label}" "${line}"
    done
}

# --- starting them -----------------------------------------------------------
#
# Upstream only applies Restart= from its init loop, so the boot units are
# started *by* that loop, in the background: `systemctl --init start UNITS`
# starts them and then stays, checking every few seconds for one that failed
# and restarting it. sshd stays the process the entrypoint exec's, and tini
# (PID 1 of the container) reaps the loop like the add-on's other background
# jobs.
#
# `--init start`, not upstream's `init UNITS`: the latter leaves the loop as
# soon as none of its units is *active*, and a crashed unit is "failed", not
# active - so with a single Restart=always unit that crashed, the loop exited
# instead of restarting it (tried, and that is what it did). `--init start`
# runs until it is signalled. Never `init` with no units either: that is
# upstream's `default`, which starts everything enabled, baseline included.
#
# Which units the loop watches is fixed when it starts: the ones passed here.
# A unit you start later over SSH runs, but nothing restarts it if it dies,
# until the next add-on start - and then only if it is enabled.
#
# Stopping the add-on is best-effort, as it always was: tini forwards SIGTERM
# to sshd alone, so the loop never runs its own stop and the units go when the
# container does. Nothing here waits on them, so nothing can hold up a stop.
start_boot_units() {
    local name file
    local -a units=() files=()

    while IFS= read -r name; do
        [ -n "${name}" ] && units+=("${name}")
    done < <(select_boot_units)
    [ "${#units[@]}" -gt 0 ] || return 0

    mkdir -p "${ADDON_JOURNAL_DIR}" 2>/dev/null || true
    rotate_unit_logs

    for name in "${units[@]}"; do
        file="$(unit_log_file "${name}")"
        # One forwarder per file: instances of one template share theirs.
        case " ${files[*]-} " in *" ${file} "*) continue ;; esac
        files+=("${file}")
        name="${file##*/}"
        forward_unit_log "${name%.log}" "${file}" &
    done

    "${ADDON_SYSTEMCTL}" --init start "${units[@]}" </dev/null >/dev/null &

    log "Starting enabled units: ${units[*]}"
    log "Their output is tagged with the unit name below; 'journalctl -u <unit>' has it too."
}
